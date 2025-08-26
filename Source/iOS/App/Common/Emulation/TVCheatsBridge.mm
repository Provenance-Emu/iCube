// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVCheatsBridge.h"

#import "Common/FileUtil.h"
#import "Common/IniFile.h"
#import "Common/StringUtil.h"

#import "Core/ConfigManager.h"
#import "Core/GeckoCode.h"
#import "Core/GeckoCodeConfig.h"
#import "Core/ActionReplay.h"
#import "Core/ARDecrypt.h"
#import "FoundationStringUtil.h"

@implementation TVGeckoCodeInfo
- (instancetype)initWithName:(NSString*)name enabled:(BOOL)enabled userDefined:(BOOL)userDefined {
    if (self = [super init]) { _name = name; _enabled = enabled; _userDefined = userDefined; }
    return self;
}
@end

@implementation TVActionReplayCodeInfo
- (instancetype)initWithName:(NSString*)name enabled:(BOOL)enabled userDefined:(BOOL)userDefined {
    if (self = [super init]) { _name = name; _enabled = enabled; _userDefined = userDefined; }
    return self;
}
@end

@implementation TVCheatsBridge

+ (void)downloadGeckoCodesForGameId:(NSString*)gameId
                           revision:(NSInteger)revision
                          gametdbId:(NSString*)gametdbId
                          completion:(void(^)(BOOL success, NSInteger downloadedCount, NSInteger addedCount))completion
{
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		Common::IniFile gameIniLocal;
		const std::string iniPath = std::string(File::GetUserPath(D_GAMESETTINGS_IDX)).append([gameId UTF8String]).append(".ini");
		gameIniLocal.Load(iniPath);
		const Common::IniFile gameIniDefault = SConfig::LoadDefaultGameIni([gameId UTF8String], (int)revision);
		std::vector<Gecko::GeckoCode> existing = Gecko::LoadCodes(gameIniDefault, gameIniLocal);
		bool ok = false;
		std::vector<Gecko::GeckoCode> downloaded = Gecko::DownloadCodes([gametdbId UTF8String], &ok);
		if (!ok) {
			dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, 0, 0); });
			return;
		}
		std::size_t added = 0;
		for (const auto& code : downloaded) {
			auto it = std::find(existing.begin(), existing.end(), code);
			if (it == existing.end()) {
				existing.push_back(code);
				++added;
			}
		}
		Gecko::SaveCodes(gameIniLocal, existing);
		gameIniLocal.Save(iniPath);
		dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, (NSInteger)downloaded.size(), (NSInteger)added); });
	});
}

+ (BOOL)addGeckoCodeForGameId:(NSString*)gameId
                      revision:(NSInteger)revision
                          name:(NSString*)name
                       creator:(NSString*)creator
                       codeText:(NSString*)codeText
                      notesText:(NSString*)notesText
{
	std::vector<Gecko::GeckoCode::Code> entries;
	std::vector<std::string> notes;
	if (notesText) {
		notes = SplitString([notesText UTF8String], '\n');
	}
	NSArray<NSString*>* lines = [codeText componentsSeparatedByString:@"\n"];
	for (NSString* line in lines) {
		if (line.length == 0) continue;
		if (std::optional<Gecko::GeckoCode::Code> c = Gecko::DeserializeLine([line UTF8String])) {
			entries.push_back(*c);
		} else {
			return NO;
		}
	}
	if (entries.empty()) {
		return NO;
	}
	Common::IniFile gameIniLocal;
	const std::string iniPath = std::string(File::GetUserPath(D_GAMESETTINGS_IDX)).append([gameId UTF8String]).append(".ini");
	gameIniLocal.Load(iniPath);
	const Common::IniFile gameIniDefault = SConfig::LoadDefaultGameIni([gameId UTF8String], (int)revision);
	std::vector<Gecko::GeckoCode> codes = Gecko::LoadCodes(gameIniDefault, gameIniLocal);
	Gecko::GeckoCode g;
	g.name = [name UTF8String];
	g.creator = [creator UTF8String];
	g.codes = std::move(entries);
	g.notes = std::move(notes);
	g.user_defined = true;
	codes.push_back(std::move(g));
	Gecko::SaveCodes(gameIniLocal, codes);
	gameIniLocal.Save(iniPath);
	return YES;
}

+ (BOOL)addActionReplayCodeForGameId:(NSString*)gameId
                             revision:(NSInteger)revision
                                  name:(NSString*)name
                               codeText:(NSString*)codeText
{
	NSArray<NSString*>* lines = [codeText componentsSeparatedByString:@"\n"];
	std::vector<ActionReplay::AREntry> entries;
	std::vector<std::string> encrypted;
	for (NSString* line in lines) {
		if (line.length == 0) continue;
		const auto parsed = ActionReplay::DeserializeLine([line UTF8String]);
		if (std::holds_alternative<ActionReplay::AREntry>(parsed)) {
			entries.push_back(std::get<ActionReplay::AREntry>(parsed));
		} else if (std::holds_alternative<ActionReplay::EncryptedLine>(parsed)) {
			encrypted.emplace_back(std::get<ActionReplay::EncryptedLine>(parsed));
		} else {
			return NO;
		}
	}
	if (!encrypted.empty()) {
		ActionReplay::DecryptARCode(encrypted, &entries);
	}
	if (entries.empty()) {
		return NO;
	}
	Common::IniFile gameIniLocal;
	const std::string iniPath = std::string(File::GetUserPath(D_GAMESETTINGS_IDX)).append([gameId UTF8String]).append(".ini");
	gameIniLocal.Load(iniPath);
	const Common::IniFile gameIniDefault = SConfig::LoadDefaultGameIni([gameId UTF8String], (int)revision);
	std::vector<ActionReplay::ARCode> codes = ActionReplay::LoadCodes(gameIniDefault, gameIniLocal);
	ActionReplay::ARCode ar;
	ar.name = [name UTF8String];
	ar.ops = std::move(entries);
	ar.user_defined = true;
	codes.push_back(std::move(ar));
	ActionReplay::SaveCodes(&gameIniLocal, codes);
	gameIniLocal.Save(iniPath);
	return YES;
}

+ (NSArray<TVGeckoCodeInfo*>*)geckoCodesForGameId:(NSString*)gameId revision:(NSInteger)revision {
	Common::IniFile gameIniLocal;
	const std::string iniPath = std::string(File::GetUserPath(D_GAMESETTINGS_IDX)).append([gameId UTF8String]).append(".ini");
	gameIniLocal.Load(iniPath);
	const Common::IniFile gameIniDefault = SConfig::LoadDefaultGameIni([gameId UTF8String], (int)revision);
	std::vector<Gecko::GeckoCode> codes = Gecko::LoadCodes(gameIniDefault, gameIniLocal);
	NSMutableArray<TVGeckoCodeInfo*>* out = [NSMutableArray arrayWithCapacity:codes.size()];
	for (const auto& c : codes) {
		[out addObject:[[TVGeckoCodeInfo alloc] initWithName:CppToFoundationString(c.name) enabled:c.enabled userDefined:c.user_defined]];
	}
	return out;
}

+ (BOOL)setGeckoCodeEnabled:(BOOL)enabled atIndex:(NSInteger)index forGameId:(NSString*)gameId revision:(NSInteger)revision {
	Common::IniFile gameIniLocal;
	const std::string iniPath = std::string(File::GetUserPath(D_GAMESETTINGS_IDX)).append([gameId UTF8String]).append(".ini");
	gameIniLocal.Load(iniPath);
	const Common::IniFile gameIniDefault = SConfig::LoadDefaultGameIni([gameId UTF8String], (int)revision);
	std::vector<Gecko::GeckoCode> codes = Gecko::LoadCodes(gameIniDefault, gameIniLocal);
	if (index < 0 || (size_t)index >= codes.size()) return NO;
	codes[(size_t)index].enabled = enabled;
	Gecko::SaveCodes(gameIniLocal, codes);
	gameIniLocal.Save(iniPath);
	return YES;
}

+ (NSArray<TVActionReplayCodeInfo*>*)actionReplayCodesForGameId:(NSString*)gameId revision:(NSInteger)revision {
	Common::IniFile gameIniLocal;
	const std::string iniPath = std::string(File::GetUserPath(D_GAMESETTINGS_IDX)).append([gameId UTF8String]).append(".ini");
	gameIniLocal.Load(iniPath);
	const Common::IniFile gameIniDefault = SConfig::LoadDefaultGameIni([gameId UTF8String], (int)revision);
	std::vector<ActionReplay::ARCode> codes = ActionReplay::LoadCodes(gameIniDefault, gameIniLocal);
	NSMutableArray<TVActionReplayCodeInfo*>* out = [NSMutableArray arrayWithCapacity:codes.size()];
	for (const auto& c : codes) {
		[out addObject:[[TVActionReplayCodeInfo alloc] initWithName:CppToFoundationString(c.name) enabled:c.enabled userDefined:c.user_defined]];
	}
	return out;
}

+ (BOOL)setActionReplayCodeEnabled:(BOOL)enabled atIndex:(NSInteger)index forGameId:(NSString*)gameId revision:(NSInteger)revision {
	Common::IniFile gameIniLocal;
	const std::string iniPath = std::string(File::GetUserPath(D_GAMESETTINGS_IDX)).append([gameId UTF8String]).append(".ini");
	gameIniLocal.Load(iniPath);
	const Common::IniFile gameIniDefault = SConfig::LoadDefaultGameIni([gameId UTF8String], (int)revision);
	std::vector<ActionReplay::ARCode> codes = ActionReplay::LoadCodes(gameIniDefault, gameIniLocal);
	if (index < 0 || (size_t)index >= codes.size()) return NO;
	codes[(size_t)index].enabled = enabled;
	ActionReplay::SaveCodes(&gameIniLocal, codes);
	gameIniLocal.Save(iniPath);
	return YES;
}

@end
