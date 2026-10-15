#!/usr/bin/env python3
"""Regenerates Source/iOS/App/Common/Mods/Browser/ModGameTable.json.

The table maps a GameBanana game id to the Dolphin/GameTDB game ids of the same title
(every region). GameBanana ids come from the public NameMatch endpoint, one request per
second; the Dolphin ids are hardcoded below and checked against Data/Sys/wiitdb-en.txt so a
typo cannot ship. Run from anywhere:

    python3 Tools/mods/gen_mod_game_table.py            # rewrite the JSON
    python3 Tools/mods/gen_mod_game_table.py --dry-run  # print what NameMatch returns

A title whose exact GameBanana name is not among the NameMatch results is reported and makes
the run fail: fix its entry (`query` / `banana_name`) instead of taking the first record.
"""

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://gamebanana.com/apiv11/Util/Game/NameMatch"
USER_AGENT = "iCube/1.0 (mod browser table generator)"
REQUEST_GAP_SECONDS = 1.0

REPO = Path(__file__).resolve().parents[2]
OUTPUT = REPO / "Source/iOS/App/Common/Mods/Browser/ModGameTable.json"
WIITDB = REPO / "Data/Sys/wiitdb-en.txt"

# Ids the table must keep resolving to; a mismatch means NameMatch changed under us.
PINNED = {"Super Smash Bros. Melee": 5706, "Mario Kart Wii": 5896, "Super Smash Bros. Brawl": 5678}


def entry(name, ids, query=None, banana_name=None):
    return {"name": name, "ids": ids.split(), "query": query or name, "banana_name": banana_name or name}


TITLES = [
    entry("Super Smash Bros. Melee", "GALE01 GALJ01 GALP01", query="Melee"),
    entry("Super Smash Bros. Brawl", "RSBE01 RSBJ01 RSBP01 RSBK01", query="Brawl"),
    entry("Mario Kart Wii", "RMCE01 RMCJ01 RMCP01 RMCK01"),
    entry("Mario Kart: Double Dash!!", "GM4E01 GM4J01 GM4P01 GM4K01", query="Double Dash"),
    entry("New Super Mario Bros. Wii", "SMNE01 SMNJ01 SMNP01 SMNK01"),
    entry("Super Mario Galaxy", "RMGE01 RMGJ01 RMGP01 RMGK01"),
    entry("Super Mario Galaxy 2", "SB4E01 SB4J01 SB4P01 SB4K01"),
    entry("Super Mario Sunshine", "GMSE01 GMSJ01 GMSP01 GMSK01"),
    entry("The Legend of Zelda: The Wind Waker", "GZLE01 GZLJ01 GZLP01", query="Wind Waker"),
    entry("The Legend of Zelda: Twilight Princess", "GZ2E01 GZ2J01 GZ2P01 RZDE01 RZDJ01 RZDP01 RZDK01", query="Twilight Princess"),
    entry("The Legend of Zelda: Skyward Sword", "SOUE01 SOUJ01 SOUP01 SOUK01", query="Skyward Sword"),
    entry("The Legend of Zelda: Four Swords Adventures", "G4SE01 G4SJ01 G4SP01", query="Four Swords"),
    entry("Paper Mario: The Thousand-Year Door", "G8ME01 G8MJ01 G8MP01 G8MK01", query="Paper Mario", banana_name="Paper Mario: The Thousand Year Door"),
    entry("Super Paper Mario", "R8PE01 R8PJ01 R8PP01 R8PK01"),
    entry("F-Zero GX", "GFZE01 GFZJ01 GFZP01"),
    entry("Metroid Prime", "GM8E01 GM8J01 GM8P01 GM8K01 R3IJ01"),
    entry("Metroid Prime 2: Echoes", "G2ME01 G2MJ01 G2MP01 G2MK01", query="Metroid Prime 2"),
    entry("Metroid Prime 3: Corruption", "RM3E01 RM3J01 RM3P01", query="Metroid Prime 3"),
    entry("Metroid Prime Trilogy", "R3ME01 R3MP01", query="Metroid Prime", banana_name="Metroid Prime: Trilogy"),
    entry("Pikmin", "GPIE01 GPIJ01 GPIP01 R9IE01 R9IJ01 R9IK01 R9IP01"),
    entry("Pikmin 2", "GPVE01 GPVJ01 GPVP01 R92E01 R92J01 R92P01"),
    entry("Luigi's Mansion", "GLME01 GLMJ01 GLMP01 GLMK01"),
    entry("Kirby Air Ride", "GKYE01 GKYJ01 GKYP01"),
    entry("Kirby's Return to Dream Land", "SUKE01 SUKJ01 SUKK01"),
    entry("Kirby's Epic Yarn", "RK5E01 RK5J01 RK5K01 RK5P01"),
    entry("Sonic Adventure 2 Battle", "GSNE8P GSNP8P GSBJ8P", query="Sonic Adventure 2", banana_name="Sonic Adventure 2"),
            entry("Sonic Riders", "GXEE8P GXEJ8P GXEP8P", banana_name="Sonic Riders (GameCube)"),
    entry("Sonic Colors", "SNCE8P SNCJ8P"),
    entry("Sonic Unleashed", "RSVE8P RSVP8P", banana_name="Sonic Unleashed (Wii)"),
    entry("Donkey Kong Country Returns", "SF8E01 SF8J01 SF8P01"),
    entry("Animal Crossing", "GAFE01 GAFP01 GAFU01 GAFJ01"),
    entry("Animal Crossing: City Folk", "RUUE01 RUUP01 RUUJ01 RUUK01"),
    entry("Mario Party 4", "GMPE01 GMPJ01 GMPP01"),
    entry("Mario Party 5", "GP5E01 GP5J01 GP5P01"),
    entry("Mario Party 6", "GP6E01 GP6J01 GP6P01"),
    entry("Mario Party 7", "GP7E01 GP7J01 GP7P01"),
    entry("Mario Party 8", "RM8E01 RM8J01 RM8P01 RM8K01"),
    entry("Mario Party 9", "SSQE01 SSQJ01 SSQP01 SSQK01"),
    entry("Mario Strikers Charged", "R4QE01 R4QJ01 R4QP01"),
    entry("Super Mario Strikers", "G4QE01 G4QJ01"),
    entry("Mario Superstar Baseball", "GYQE01 GYQP01"),
    entry("Mario Super Sluggers", "RMBE01 RMBJ01 RMBP01"),
    entry("Wii Sports", "RSPE01 RSPJ01 RSPP01 RSPK01"),
    entry("Wii Sports Resort", "RZTE01 RZTJ01 RZTP01 RZTK01"),
    entry("Pokemon Colosseum", "GC6E01 GC6J01 GC6P01", banana_name="Pokémon Colosseum"),
    entry("Pokemon XD: Gale of Darkness", "GXXE01 GXXJ01 GXXP01", query="Pokemon XD", banana_name="Pokemon XD Gale of Darkness"),
    entry("Fire Emblem: Path of Radiance", "GFEE01 GFEJ01 GFEP01"),
    entry("Fire Emblem: Radiant Dawn", "RFEE01 RFEJ01 RFEP01"),
        entry("Dragon Ball Z: Budokai Tenkaichi 3", "RDSE70 RDSPAF", query="Budokai Tenkaichi 3"),
    entry("Star Fox Adventures", "GSAE01 GSAJ01 GSAP01"),
]


def fetch_candidates(query):
    url = f"{API}?{urllib.parse.urlencode({'_sName': query})}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response).get("_aRecords", [])


def load_wiitdb():
    ids = {}
    for line in WIITDB.read_text(encoding="utf-8").splitlines():
        game_id, separator, title = line.partition(" = ")
        if separator and len(game_id) == 6:
            ids[game_id] = title
    return ids


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="print NameMatch candidates, write nothing")
    args = parser.parse_args()

    known_ids = load_wiitdb() if WIITDB.exists() else None
    games, failures = [], []
    for index, title in enumerate(TITLES):
        if index:
            time.sleep(REQUEST_GAP_SECONDS)
        candidates = fetch_candidates(title["query"])
        if args.dry_run:
            print(f"{title['name']!r} -> {[(c['_idRow'], c['_sName']) for c in candidates]}")
            continue
        wanted = title["banana_name"].casefold()
        matches = [c for c in candidates if c.get("_sName", "").casefold() == wanted]
        if len(matches) != 1:
            failures.append(f"{title['name']}: no unique exact match in {[c['_sName'] for c in candidates]}")
            continue
        record = matches[0]
        ids = title["ids"]
        if known_ids is not None:
            unknown = [i for i in ids if i not in known_ids]
            for game_id in unknown:
                print(f"note: {game_id} ({title['name']}) is not in wiitdb-en.txt, dropped", file=sys.stderr)
            ids = [i for i in ids if i in known_ids]
        if not ids:
            failures.append(f"{title['name']}: none of its game ids are in wiitdb-en.txt")
            continue
        pinned = PINNED.get(title["name"])
        if pinned is not None and pinned != record["_idRow"]:
            failures.append(f"{title['name']}: NameMatch returned {record['_idRow']}, expected {pinned}")
            continue
        games.append({
            "bananaID": record["_idRow"],
            "name": title["name"],
            "iconURL": record.get("_sIconUrl", ""),
            "gameIDs": ids,
        })

    if args.dry_run:
        return 0
    for failure in failures:
        print(f"error: {failure}", file=sys.stderr)
    if failures:
        return 1
    ids = [game["bananaID"] for game in games]
    if len(ids) != len(set(ids)):
        print("error: two titles resolved to the same GameBanana game", file=sys.stderr)
        return 1
    games.sort(key=lambda game: game["name"].casefold())
    OUTPUT.write_text(json.dumps({"version": 1, "games": games}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {len(games)} games, {sum(len(g['gameIDs']) for g in games)} game ids to {OUTPUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
