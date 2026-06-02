import Foundation

/// Utility for mapping GameCube/Wii region codes to flag emojis
struct RegionFlagMapper {
  /// Maps a region/country code to its corresponding flag emoji
  /// - Parameter countryCode: The region code (e.g., "USA", "JPN", "EUR", "PAL")
  /// - Returns: Flag emoji string, or empty string if no mapping found
  static func flagEmoji(for countryCode: String) -> String {
    let normalized = countryCode.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)

    switch normalized {
    // North America
    case "USA", "NTSC-U", "US", "AMERICA", "NORTH AMERICA":
      return "🇺🇸"
    case "CANADA", "CA":
      return "🇨🇦"

    // Japan
    case "JPN", "JAP", "JAPAN", "NTSC-J", "JP":
      return "🇯🇵"

    // Europe/PAL regions
    case "EUR", "EUROPE", "PAL", "NTSC-PAL", "EU":
      return "🇪🇺"
    case "UK", "UNITED KINGDOM", "GB", "BRITAIN":
      return "🇬🇧"
    case "GERMANY", "DE", "GER":
      return "🇩🇪"
    case "FRANCE", "FR", "FRA":
      return "🇫🇷"
    case "ITALY", "IT", "ITA":
      return "🇮🇹"
    case "SPAIN", "ES", "ESP":
      return "🇪🇸"
    case "NETHERLANDS", "NL", "NLD":
      return "🇳🇱"

    // Other regions
    case "KOREA", "KOR", "KR", "SOUTH KOREA":
      return "🇰🇷"
    case "AUSTRALIA", "AU", "AUS":
      return "🇦🇺"
    case "BRAZIL", "BR", "BRA":
      return "🇧🇷"

    // Unknown/World
    case "WORLD", "WORLDWIDE", "INTERNATIONAL", "MULTI":
      return "🌍"

    default:
      return ""
    }
  }

  /// Gets a human-readable region name with flag emoji
  /// - Parameter countryCode: The region code
  /// - Returns: Formatted string with flag emoji and region name, or just the original code if no mapping
  static func flagWithRegionName(for countryCode: String) -> String {
    let flag = flagEmoji(for: countryCode)
    let normalized = countryCode.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)

    if flag.isEmpty {
      return countryCode // Return original if no flag mapping
    }

    let regionName: String
    switch normalized {
    case "USA", "NTSC-U", "US", "AMERICA", "NORTH AMERICA":
      regionName = "USA"
    case "CANADA", "CA":
      regionName = "Canada"
    case "JPN", "JAP", "JAPAN", "NTSC-J", "JP":
      regionName = "Japan"
    case "EUR", "EUROPE", "PAL", "NTSC-PAL", "EU":
      regionName = "Europe"
    case "UK", "UNITED KINGDOM", "GB", "BRITAIN":
      regionName = "UK"
    case "GERMANY", "DE", "GER":
      regionName = "Germany"
    case "FRANCE", "FR", "FRA":
      regionName = "France"
    case "ITALY", "IT", "ITA":
      regionName = "Italy"
    case "SPAIN", "ES", "ESP":
      regionName = "Spain"
    case "NETHERLANDS", "NL", "NLD":
      regionName = "Netherlands"
    case "KOREA", "KOR", "KR", "SOUTH KOREA":
      regionName = "Korea"
    case "AUSTRALIA", "AU", "AUS":
      regionName = "Australia"
    case "BRAZIL", "BR", "BRA":
      regionName = "Brazil"
    case "WORLD", "WORLDWIDE", "INTERNATIONAL", "MULTI":
      regionName = "World"
    default:
      regionName = countryCode
    }

    return "\(flag) \(regionName)"
  }

  /// Gets just the flag emoji, suitable for compact display
  /// - Parameter countryCode: The region code
  /// - Returns: Flag emoji or "🌍" as fallback for unknown regions
  static func compactFlag(for countryCode: String) -> String {
    let flag = flagEmoji(for: countryCode)
    return flag.isEmpty ? "🌍" : flag
  }
}
