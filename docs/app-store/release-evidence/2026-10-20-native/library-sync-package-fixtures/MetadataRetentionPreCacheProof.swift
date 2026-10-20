import Foundation
@main enum Retention {
 static func main() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataRetention-\(UUID())")
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:dir)}
  let store = try LibraryMetadataStore(directoryURL:dir)
  for index in 0..<32 {
   let id = LibraryMetadataStore.Identity.game(gameID:"CASE\(index)",discNumber:0,revision:0)!
   let cover = Data(repeating:UInt8(index),count:256*1024)
   let bytes = try JSONSerialization.data(withJSONObject:[id.rawValue+":title":["updatedAt":1,"value":"Title \(index)"],id.rawValue+":cover":["updatedAt":1,"value":cover.base64EncodedString()]])
   try bytes.write(to:dir.appendingPathComponent(id.fileName))
   _ = try store.draft(for:id).title
  }
  let fields = Dictionary(uniqueKeysWithValues:Mirror(reflecting:store).children.compactMap { child in child.label.map {($0,child.value)} })
  let documents = fields["documents"] as! [LibraryMetadataStore.Identity:[String:Any]]
  let projections = fields["projections"] as! [LibraryMetadataStore.Identity:LibraryMetadataStore.Draft]
  let encoded = documents.values.reduce(0) { total, object in total + object.filter{$0.key.hasSuffix(":cover")}.values.reduce(0) { sum, raw in sum + (((raw as? [String:Any])?["value"] as? String)?.utf8.count ?? 0) } }
  let decoded = projections.values.reduce(0) {$0+($1.coverData?.count ?? 0)}
  print("titleOnlyReads=32 retainedDocuments=\(documents.count) retainedDrafts=\(projections.count) base64Bytes=\(encoded) decodedCoverBytes=\(decoded) combinedCoverPayloadBytes=\(encoded+decoded)")
 }
}
