"""Builds a minimal GameCube disc whose apploader runs an illegal opcode (ICUBE-AW test).

The apploader's close() returns TEST, so TEST runs on the configured CPU engine after the
emulated BS2 finishes. TEST copies HANDLER to the program-exception vector 0x700, then executes
0x00000001. HANDLER (MSR.IR/DR off, physical addresses) stores SRR0 at 0x1800, SRR1 at 0x1804,
bumps a hit counter at 0x1808, returns with rfi to SRR0+4 (skipping the bad word), and TEST then
writes 0xC0DEC0DE to 0x180C and spins. Read 0x80001800 with /api/debug/mem.

Expected 16 bytes at 0x80001800: 81200078 (SRR0 = the bad word), SRR1 with 0x00080000 set
(IllegalInstruction), the low-memory word at 0x1808 plus one, then c0dec0de.

    python3 make_disc.py ZAWE01.iso         # handler disc (game ID ZAWE01)
    python3 make_disc.py ZAXE01.iso loop    # 0x700 holds an illegal word too (game ID ZAXE01):
                                            # the core must keep running and still stop

Copy the image into the app's Documents/Software, relaunch, set mainCpuCore with
/api/settings/bulk, then POST /api/debug/boot {"gameID": "ZAWE01"}. In the simulator, also set
gfxShaderCompilationMode 0 and gfxWaitForShadersBeforeStarting false first: the ubershader
pipelines fail to compile there and the boot waits on that panic alert.
"""
import struct, sys
LOOP = len(sys.argv) > 2 and sys.argv[2] == "loop"

BASE = 0x81200000
def lis(d, imm): return (15 << 26) | (d << 21) | (imm & 0xFFFF)
def addi(d, a, imm): return (14 << 26) | (d << 21) | (a << 16) | (imm & 0xFFFF)
def ori(a, s, imm): return (24 << 26) | (s << 21) | (a << 16) | (imm & 0xFFFF)
def stw(s, d, a): return (36 << 26) | (s << 21) | (a << 16) | (d & 0xFFFF)
def lwz(d, off, a): return (32 << 26) | (d << 21) | (a << 16) | (off & 0xFFFF)
def mfspr(d, spr): return (31 << 26) | (d << 21) | ((spr & 31) << 16) | ((spr >> 5) << 11) | (339 << 1)
def mtspr(spr, s): return (31 << 26) | (s << 21) | ((spr & 31) << 16) | ((spr >> 5) << 11) | (467 << 1)
def dcbst(b): return (31 << 26) | (b << 11) | (54 << 1)
def icbi(b): return (31 << 26) | (b << 11) | (982 << 1)
SYNC, ISYNC, BLR, RFI, SPIN = 0x7C0004AC, 0x4C00012C, 0x4E800020, 0x4C000064, 0x48000000
def bdnz(rel): return (16 << 26) | (16 << 21) | (rel & 0xFFFC)
ILLEGAL = 0x00000001

def build():
    labels, code = {}, []
    def at(name): labels[name] = len(code) * 4
    # entry(r3=&init, r4=&main, r5=&close)
    at("entry")
    entry_fix = len(code)
    code += [lis(6, BASE >> 16), 0, stw(7, 0, 3), 0, stw(7, 0, 4), 0, stw(7, 0, 5), BLR]
    at("init"); code += [BLR]
    at("main"); code += [addi(3, 0, 0), BLR]
    at("close"); close_fix = len(code); code += [lis(3, BASE >> 16), 0, BLR]
    at("test")
    test_fix = len(code)
    code += [lis(8, 0x8000), ori(8, 8, 0x0700), lis(9, BASE >> 16), 0, 0, mtspr(9, 10)]
    at("copy")
    code += [lwz(11, 0, 9), stw(11, 0, 8), dcbst(8), SYNC, icbi(8), addi(8, 8, 4), addi(9, 9, 4)]
    code += [bdnz(labels["copy"] - len(code) * 4), SYNC, ISYNC]
    at("fault"); code += [ILLEGAL]
    # Back from the handler: mark that execution resumed after the bad word.
    code += [lis(12, 0x8000), lis(13, 0xC0DE), ori(13, 13, 0xC0DE), stw(13, 0x180C, 12), SPIN]
    at("handler")
    handler = [mfspr(3, 26), mfspr(4, 27), addi(5, 0, 0x1800), stw(3, 0, 5), stw(4, 4, 5),
               lwz(6, 8, 5), addi(6, 6, 1), stw(6, 8, 5),
               addi(3, 3, 4), mtspr(26, 3), SYNC, RFI]
    if LOOP:
        handler = [ILLEGAL]
    code += handler
    a = lambda n: labels[n]
    code[entry_fix + 1] = addi(7, 6, a("init"))
    code[entry_fix + 3] = addi(7, 6, a("main"))
    code[entry_fix + 5] = addi(7, 6, a("close"))
    code[close_fix + 1] = addi(3, 3, a("test"))
    code[test_fix + 3] = addi(9, 9, a("handler"))
    code[test_fix + 4] = addi(10, 0, len(handler))
    return b"".join(struct.pack(">I", w) for w in code), labels

def disc(out):
    body, labels = build()
    img = bytearray(0x200000)
    img[0:6] = b"ZAXE01" if LOOP else b"ZAWE01"
    img[0x1C:0x20] = struct.pack(">I", 0xC2339F3D)
    img[0x20:0x20 + 21] = b"iCube unknown op test"
    app = 0x2440
    img[app:app + 10] = b"2026/11/04"
    img[app + 0x10:app + 0x1C] = struct.pack(">III", BASE + labels["entry"], len(body), 0)
    img[app + 0x20:app + 0x20 + len(body)] = body
    open(out, "wb").write(img)
    print(f"fault pc = {BASE + labels['fault']:#010x}, handler words copied, image {len(img)} bytes")

disc(sys.argv[1])
