#!/bin/bash

# Dolphin macOS Build and Debug Setup Script
# This script builds Dolphin and applies proper debug entitlements

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
BUILD_DIR="/Users/jmattiello/Workspace/Provenance/Provenance/Cores/Dolphin/dolphin-ios/build-macos-app"
SOURCE_DIR="/Users/jmattiello/Workspace/Provenance/Provenance/Cores/Dolphin/dolphin-ios"
APP_PATH="$BUILD_DIR/Binaries/Dolphin.app"
ENTITLEMENTS_FILE="$SOURCE_DIR/debug.entitlements"

echo -e "${BLUE}=== Dolphin macOS Build and Debug Setup ===${NC}"

# Function to print status
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in the right directory
if [ ! -f "$SOURCE_DIR/CMakeLists.txt" ]; then
    print_error "CMakeLists.txt not found. Please run this script from the Dolphin source directory."
    exit 1
fi

# Create debug entitlements file
print_status "Creating debug entitlements file..."
cat > "$ENTITLEMENTS_FILE" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.get-task-allow</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.debugger</key>
    <true/>
</dict>
</plist>
EOF

# Build the project
print_status "Building Dolphin..."
cd "$BUILD_DIR"

# Clean and build
make -j$(sysctl -n hw.ncpu) || {
    print_error "Build failed!"
    exit 1
}

print_status "Build completed successfully!"

# Check if app bundle exists
if [ ! -d "$APP_PATH" ]; then
    print_error "App bundle not found at $APP_PATH"
    exit 1
fi

# Apply debug entitlements
print_status "Applying debug entitlements and codesigning..."

# Remove existing signature first
codesign --remove-signature "$APP_PATH" 2>/dev/null || true

# Sign with debug entitlements and local signing identity
codesign -f -s - --entitlements "$ENTITLEMENTS_FILE" --deep --options=runtime "$APP_PATH" || {
    print_error "Codesigning failed!"
    exit 1
}

# Verify the signature and entitlements
print_status "Verifying code signature and entitlements..."
codesign -dv "$APP_PATH"
echo ""
print_status "Entitlements applied:"
codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -A 20 "<dict>"

# Test basic functionality
print_status "Testing basic functionality..."
"$APP_PATH/Contents/MacOS/Dolphin" --version || {
    print_warning "Basic functionality test failed, but this might be expected"
}

print_status "Setup complete!"
echo -e "${GREEN}=== Success ===${NC}"
echo "Dolphin has been built and prepared for debugging."
echo "App location: $APP_PATH"
echo "You can now:"
echo "  1. Run the app directly: open '$APP_PATH'"
echo "  2. Debug with lldb: lldb '$APP_PATH/Contents/MacOS/Dolphin'"
echo "  3. Debug with Xcode: open the app bundle in Xcode debugger"

# Optional: Open in lldb
echo ""
read -p "Would you like to open lldb now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_status "Opening lldb..."
    exec lldb "$APP_PATH/Contents/MacOS/Dolphin"
fi
