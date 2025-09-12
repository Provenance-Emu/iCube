import SwiftUI
import Foundation
import Combine
#if canImport(SafariServices)
import SafariServices
#endif

/// A delightful RSS feed viewer for Dolphin emulator blog posts
struct DolphinBlogView: View {
  @StateObject private var feedManager = DolphinRSSFeedManager()
  @State private var selectedPost: BlogPost?
  @State private var refreshing = false

  var body: some View {
    NavigationView {
      ZStack {
        // Gradient background
        LinearGradient(
          colors: [Color.blue.opacity(0.1), Color.cyan.opacity(0.05)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        ScrollView {
          LazyVStack(spacing: 16) {
            // Header
            headerView

            // Blog posts
            if feedManager.isLoading && feedManager.posts.isEmpty {
              loadingView
            } else if let error = feedManager.error {
              errorView(error)
            } else {
              ForEach(feedManager.posts) { post in
                BlogPostCard(post: post) {
                  selectedPost = post
                }
              }

              // Footer
              footerView
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 20)
        }
        .refreshable {
          await refreshFeed()
        }
      }
      .navigationTitle("Dolphin Blog")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: {
            Task { await refreshFeed() }
          }) {
            Image(systemName: refreshing ? "arrow.clockwise" : "arrow.clockwise")
              .rotationEffect(.degrees(refreshing ? 360 : 0))
              .animation(refreshing ? .linear(duration: 1.0).repeatForever(autoreverses: false) : .default, value: refreshing)
          }
          .disabled(refreshing)
        }
      }
      .sheet(item: $selectedPost) { post in
        BlogPostDetailView(post: post)
      }
      .task {
        await loadInitialFeed()
      }
    }
  }

  private var headerView: some View {
    VStack(spacing: 12) {
      // Swimming dolphins header
      HStack(spacing: 20) {
        ForEach(0..<3, id: \.self) { index in
          SwimmingDolphinHeader(delay: Double(index) * 0.3)
        }
      }
      .frame(height: 60)

      Text("Latest from the Dolphin Team")
        .font(.title2)
        .fontWeight(.semibold)
        .foregroundColor(.primary)

      Text("🐬 Development updates, progress reports, and announcements 🌊")
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }
        .padding(.vertical, 20)
  }

  private var footerView: some View {
    VStack(spacing: 16) {
      Divider()
        .padding(.horizontal, 20)

      VStack(spacing: 12) {
        // Dolphin project info
        HStack(spacing: 8) {
          Image("DolphinLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 24)
            .foregroundColor(.blue.opacity(0.7))

          Text("Powered by Dolphin Emulator")
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
        }

        Text("Open-source GameCube and Wii emulator")
          .font(.caption)
          .foregroundColor(.secondary)

        // Links
        HStack(spacing: 20) {
          Link("Visit Website", destination: URL(string: "https://dolphin-emu.org")!)
            .font(.caption)
            .foregroundColor(.blue)

          Link("GitHub", destination: URL(string: "https://github.com/dolphin-emu/dolphin")!)
            .font(.caption)
            .foregroundColor(.blue)
        }
      }
      .padding(.vertical, 16)
      .padding(.horizontal, 20)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .padding(.top, 20)
  }

  private var loadingView: some View {
    VStack(spacing: 20) {
      DolphinLoadingView(message: "Fetching latest blog posts...")

      // Skeleton loading cards
      ForEach(0..<3, id: \.self) { _ in
        BlogPostSkeletonCard()
      }
    }
  }

  private func errorView(_ error: String) -> some View {
    VStack(spacing: 16) {
      DolphinErrorView(
        title: "Unable to Load Blog",
        message: error + "\n\nCheck your internet connection and try again.",
        retryAction: {
          Task { await refreshFeed() }
        }
      )
    }
    .padding(.vertical, 40)
  }

  private func loadInitialFeed() async {
    await feedManager.loadFeed()
  }

  private func refreshFeed() async {
    refreshing = true
    await feedManager.refreshFeed()
    refreshing = false
  }
}

/// Individual blog post card
struct BlogPostCard: View {
  let post: BlogPost
  let onTap: () -> Void
  @State private var isAnimating = false

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 12) {
        // Date and category
        HStack {
          Text(post.formattedDate)
            .font(.caption)
            .foregroundColor(.secondary)

          Spacer()

          if post.isProgressReport {
            Text("PROGRESS REPORT")
              .font(.caption2)
              .fontWeight(.bold)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Color.blue.opacity(0.2))
              .foregroundColor(.blue)
              .clipShape(Capsule())
          }
        }

        // Title
        Text(post.title)
          .font(.headline)
          .fontWeight(.semibold)
          .foregroundColor(.primary)
          .multilineTextAlignment(.leading)
          .lineLimit(3)

        // Summary
        if !post.summary.isEmpty {
          Text(post.summary)
            .font(.body)
            .foregroundColor(.secondary)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
        }

        // Author and read more
        HStack {
          if !post.author.isEmpty {
            HStack(spacing: 4) {
              Image(systemName: "person.circle.fill")
                .foregroundColor(.blue.opacity(0.7))
              Text("by \(post.author)")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }

          Spacer()

          HStack(spacing: 4) {
            Text("Read More")
              .font(.caption)
              .fontWeight(.medium)
              .foregroundColor(.blue)

            Image(systemName: "arrow.right.circle.fill")
              .foregroundColor(.blue)
              .scaleEffect(isAnimating ? 1.1 : 1.0)
              .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isAnimating)
          }
        }
      }
      .padding(16)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.white.opacity(0.1), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
    }
    .buttonStyle(.plain)
    .onAppear {
      isAnimating = true
    }
  }
}

/// Swimming dolphin for header animation
struct SwimmingDolphinHeader: View {
  let delay: Double
  @State private var isSwimming = false
  @State private var offset: CGFloat = 0

  var body: some View {
    Image("DolphinLogo")
      .resizable()
      .scaledToFit()
      .frame(width: 32, height: 32)
      .foregroundColor(.blue.opacity(0.8))
      .scaleEffect(isSwimming ? 1.1 : 0.9)
      .rotationEffect(.degrees(isSwimming ? 5 : -5))
      .offset(x: offset)
      .animation(
        .easeInOut(duration: 2.0 + delay)
          .repeatForever(autoreverses: true)
          .delay(delay),
        value: isSwimming
      )
      .animation(
        .easeInOut(duration: 3.0)
          .repeatForever(autoreverses: true)
          .delay(delay * 0.5),
        value: offset
      )
      .onAppear {
        isSwimming = true
        offset = 10
      }
  }
}

/// Skeleton loading card
struct BlogPostSkeletonCard: View {
  @State private var shimmer = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.3))
          .frame(width: 80, height: 12)
        Spacer()
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.gray.opacity(0.3))
          .frame(width: 100, height: 20)
      }

      VStack(alignment: .leading, spacing: 8) {
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.3))
          .frame(height: 20)
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.3))
          .frame(width: 200, height: 20)
      }

      VStack(alignment: .leading, spacing: 6) {
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.2))
          .frame(height: 16)
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.2))
          .frame(height: 16)
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.2))
          .frame(width: 150, height: 16)
      }
    }
    .padding(16)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .opacity(shimmer ? 0.6 : 1.0)
    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: shimmer)
    .onAppear { shimmer = true }
  }
}

/// Blog post data model
struct BlogPost: Identifiable, Codable {
  let id = UUID()
  let title: String
  let link: String
  let summary: String
  let author: String
  let pubDate: Date
  let guid: String

  var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: pubDate)
  }

  var isProgressReport: Bool {
    return title.lowercased().contains("progress report")
  }
}

/// RSS Feed Manager
@MainActor
class DolphinRSSFeedManager: ObservableObject {
  @Published var posts: [BlogPost] = []
  @Published var isLoading = false
  @Published var error: String?

  private let feedURL = "https://dolphin-emu.org/blog/feeds/"
  private let session = URLSession.shared

  func loadFeed() async {
    guard !isLoading else { return }

    isLoading = true
    error = nil

    do {
      let posts = try await fetchRSSFeed()
      self.posts = posts
    } catch {
      self.error = error.localizedDescription
    }

    isLoading = false
  }

  func refreshFeed() async {
    do {
      let posts = try await fetchRSSFeed()
      self.posts = posts
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func fetchRSSFeed() async throws -> [BlogPost] {
    guard let url = URL(string: feedURL) else {
      throw URLError(.badURL)
    }

    let (data, response) = try await session.data(from: url)

    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
      throw URLError(.badServerResponse)
    }

    return try parseRSSFeed(data: data)
  }

  private func parseRSSFeed(data: Data) throws -> [BlogPost] {
    let parser = DolphinRSSParser()
    return try parser.parse(data: data)
  }
}

/// Simple RSS Parser for Dolphin blog feed
class DolphinRSSParser: NSObject, XMLParserDelegate {
  private var posts: [BlogPost] = []
  private var currentElement = ""
  private var currentTitle = ""
  private var currentLink = ""
  private var currentDescription = ""
  private var currentAuthor = ""
  private var currentPubDate = ""
  private var currentGuid = ""

  private var isInItem = false

  func parse(data: Data) throws -> [BlogPost] {
    posts.removeAll()

    let parser = XMLParser(data: data)
    parser.delegate = self

    guard parser.parse() else {
      throw NSError(domain: "RSSParseError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to parse RSS feed"])
    }

    return posts
  }

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
    currentElement = elementName

    if elementName == "item" {
      isInItem = true
      // Reset current item data
      currentTitle = ""
      currentLink = ""
      currentDescription = ""
      currentAuthor = ""
      currentPubDate = ""
      currentGuid = ""
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty && isInItem else { return }

    switch currentElement {
    case "title":
      currentTitle += trimmed
    case "link":
      currentLink += trimmed
    case "description":
      currentDescription += trimmed
    case "author", "dc:creator":
      currentAuthor += trimmed
    case "pubDate":
      currentPubDate += trimmed
    case "guid":
      currentGuid += trimmed
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    if elementName == "item" && isInItem {
      // Create blog post
      let dateFormatter = DateFormatter()
      dateFormatter.dateFormat = "E, dd MMM yyyy HH:mm:ss Z"
      let pubDate = dateFormatter.date(from: currentPubDate) ?? Date()

      // Clean up HTML from description
      let cleanDescription = currentDescription
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let post = BlogPost(
        title: currentTitle,
        link: currentLink,
        summary: String(cleanDescription.prefix(200)),
        author: currentAuthor,
        pubDate: pubDate,
        guid: currentGuid
      )

      posts.append(post)
      isInItem = false
    }

    currentElement = ""
  }
}

/// Detail view for reading full blog posts
struct BlogPostDetailView: View {
  let post: BlogPost
  @Environment(\.dismiss) private var dismiss
  @State private var showingSafari = false
  @State private var logoRotation = 0.0

  var body: some View {
    NavigationView {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Header with animated dolphin
          headerSection

          // Post content
          contentSection

          // Actions
          actionsSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
      }
      .background(
        LinearGradient(
          colors: [Color.blue.opacity(0.05), Color.cyan.opacity(0.02)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .navigationTitle("Blog Post")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Done") {
            dismiss()
          }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Read Full Post") {
            showingSafari = true
          }
          .foregroundColor(.blue)
        }
      }
    }
    .sheet(isPresented: $showingSafari) {
      #if canImport(SafariServices)
      if let url = URL(string: post.link) {
        SafariView(url: url)
      }
      #endif
    }
  }

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Swimming dolphin and date
      HStack {
        Image("DolphinLogo")
          .resizable()
          .scaledToFit()
          .frame(width: 40, height: 40)
          .foregroundColor(.blue)
          .rotationEffect(.degrees(logoRotation))
          .animation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true), value: logoRotation)
          .onAppear { logoRotation = 10 }

        Spacer()

        VStack(alignment: .trailing, spacing: 4) {
          Text(post.formattedDate)
            .font(.subheadline)
            .foregroundColor(.secondary)

          if post.isProgressReport {
            Text("PROGRESS REPORT")
              .font(.caption2)
              .fontWeight(.bold)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(Color.blue.opacity(0.2))
              .foregroundColor(.blue)
              .clipShape(Capsule())
          }
        }
      }

      // Title
      Text(post.title)
        .font(.title2)
        .fontWeight(.bold)
        .foregroundColor(.primary)
        .multilineTextAlignment(.leading)

      // Author
      if !post.author.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "person.circle.fill")
            .foregroundColor(.blue.opacity(0.7))
          Text("by \(post.author)")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
      }

      Divider()
    }
  }

  private var contentSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Summary
      if !post.summary.isEmpty {
        Text(post.summary)
          .font(.body)
          .foregroundColor(.primary)
          .multilineTextAlignment(.leading)
          .lineSpacing(2)
      }

      // Notice about full content
      VStack(spacing: 12) {
        HStack {
          Image(systemName: "info.circle.fill")
            .foregroundColor(.blue)
          Text("This is a preview of the blog post")
            .font(.subheadline)
            .foregroundColor(.secondary)
          Spacer()
        }

        Text("To read the complete article with images, code samples, and full details, tap \"Read Full Post\" to open it in your browser.")
          .font(.caption)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.leading)
      }
      .padding(16)
      .background(Color.blue.opacity(0.1))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }

  private var actionsSection: some View {
    VStack(spacing: 16) {
      // Read full post button
      Button(action: { showingSafari = true }) {
        HStack {
          Image(systemName: "safari")
          Text("Read Full Post on Dolphin-Emu.org")
        }
        .font(.headline)
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
          LinearGradient(
            colors: [Color.blue, Color.cyan],
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }

      // Share button
      if #available(iOS 16.0, *) {
        ShareLink(item: URL(string: post.link)!, subject: Text(post.title)) {
          HStack {
            Image(systemName: "square.and.arrow.up")
            Text("Share This Post")
          }
          .font(.subheadline)
          .foregroundColor(.blue)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .background(Color.blue.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
      } else {
        // Fallback for iOS 15 and below
        Button(action: {
          sharePost(url: post.link, title: post.title)
        }) {
          HStack {
            Image(systemName: "square.and.arrow.up")
            Text("Share This Post")
          }
          .font(.subheadline)
          .foregroundColor(.blue)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .background(Color.blue.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
      }
    }
    .padding(.top, 20)
  }
}

#if canImport(SafariServices)
struct SafariView: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> SFSafariViewController {
    return SFSafariViewController(url: url)
  }

  func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
  }
}
#endif

#if DEBUG
struct DolphinBlogView_Previews: PreviewProvider {
  static var previews: some View {
    DolphinBlogView()
      .preferredColorScheme(.dark)
  }
}
#endif
