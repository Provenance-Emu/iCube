import ProjectDescription

// Root marker + config for the iCube Tuist project.
// Lives in Source/iOS/App so $SRCROOT == this dir == the original pbxproj's $SRCROOT,
// keeping the xcconfig #include "Project/Config/..." paths and the script
// "../../../" walks valid.
let tuist = Tuist(
    compatibleXcodeVersions: .all
)
