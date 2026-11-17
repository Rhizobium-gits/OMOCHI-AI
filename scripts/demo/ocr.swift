// 録画のフレームから、隠したい文字（ホームのパスなど）の位置を macOS の文字認識（Vision）で探す（端末内だけで処理）。
//   swiftc -O scripts/demo/ocr.swift -o .build/ocr
//   .build/ocr --pattern '<正規表現>' frame-00001.png frame-00002.png … > hits.json
// 出力：{"frame-00001.png": [[x, y, w, h], …], …}（当たった部分の箱。ピクセル・左上原点。当たりの無いフレームは空の配列）
import AppKit
import Vision

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, args[0] == "--pattern", let re = try? NSRegularExpression(pattern: args[1]) else {
    FileHandle.standardError.write("usage: ocr --pattern <regex> <png>…\n".data(using: .utf8)!)
    exit(2)
}
args.removeFirst(2)

var out: [String: [[Double]]] = [:]
for path in args {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let W = Double(cg.width), H = Double(cg.height)
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["ja-JP", "en-US"]
    req.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    var hits: [[Double]] = []
    for o in req.results ?? [] {
        guard let t = o.topCandidates(1).first else { continue }
        let s = t.string
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            // 当たった部分だけの箱（取れなければ行全体）
            let b = (try? t.boundingBox(for: r))?.boundingBox ?? o.boundingBox
            hits.append([b.minX * W, (1 - b.maxY) * H, b.width * W, b.height * H])
        }
    }
    out[(path as NSString).lastPathComponent] = hits
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]))
