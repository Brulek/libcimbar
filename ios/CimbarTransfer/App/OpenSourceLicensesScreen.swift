import SwiftUI

struct OpenSourceLicensesScreen: View {
    private let entries: [LicenseEntry] = [
        LicenseEntry(
            name: "libcimbar",
            license: "Mozilla Public License 2.0",
            urlString: "https://github.com/sz3/libcimbar",
            note: String(localized: "萤传的解码用的是 libcimbar 源码，其中改过几个文件。改过的源代码依各自的许可（libcimbar 为 MPL-2.0）公开在 github.com/Brulek/libcimbar。")
        ),
        LicenseEntry(name: "OpenCV", license: "Apache License 2.0", urlString: "https://opencv.org/", note: nil),
        LicenseEntry(name: "zstd", license: "BSD License", urlString: "https://github.com/facebook/zstd", note: nil),
        LicenseEntry(name: "{fmt}", license: "MIT License", urlString: "https://github.com/fmtlib/fmt", note: nil),
        LicenseEntry(name: "wirehair", license: "BSD 3-Clause", urlString: "https://github.com/catid/wirehair", note: nil),
        LicenseEntry(name: "libcorrect", license: "BSD 3-Clause", urlString: "https://github.com/quiet/libcorrect", note: nil),
        LicenseEntry(name: "stb", license: "MIT License / Public Domain", urlString: "https://github.com/nothings/stb", note: nil),
        LicenseEntry(name: "PicoSHA2", license: "MIT License", urlString: "https://github.com/okdshin/PicoSHA2", note: nil),
        LicenseEntry(name: "concurrentqueue", license: "BSD-2-Clause / Boost", urlString: "https://github.com/cameron314/concurrentqueue", note: nil),
        LicenseEntry(name: "base91", license: "zlib License", urlString: "https://github.com/r-lyeh/base91", note: nil),
        LicenseEntry(name: "cxxopts", license: "MIT License", urlString: "https://github.com/jarro2783/cxxopts", note: nil),
        LicenseEntry(name: "intx", license: "Apache License 2.0", urlString: "https://github.com/chfast/intx", note: nil),
        LicenseEntry(name: "libpopcnt", license: "BSD 2-Clause", urlString: "https://github.com/kimwalisch/libpopcnt", note: nil)
    ]

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    LicenseRow(entry: entry)
                }
            } header: {
                Text("萤传用到了以下开源软件，感谢各位作者。")
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseEntry: Identifiable {
    let name: String
    let license: String
    let urlString: String
    let note: String?

    var id: String { name }
}

private struct LicenseRow: View {
    let entry: LicenseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.name)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(entry.license)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = entry.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let url = URL(string: entry.urlString) {
                Link(destination: url) {
                    Text(entry.urlString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let licenseText = OpenSourceLicenseTexts.texts[entry.name] {
                DisclosureGroup("许可全文") {
                    Text(licenseText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
