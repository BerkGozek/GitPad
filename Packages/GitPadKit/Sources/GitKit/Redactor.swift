import Foundation

/// Removes secrets from any text before it reaches UI, logs or error messages.
///
/// It lives in GitKit (not GitPadCore) so that errors are redacted where they are created;
/// GitPadCore and the app reuse the same function.
public enum Redactor {
    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = [
        // https://user:token@host → https://***@host
        (#"(?i)\b([a-z][a-z0-9+.\-]*://)[^/\s@]+@"#, "$1***@"),
        // Authorization headers, whatever the scheme.
        (#"(?i)(authorization:\s*)[^\r\n]+"#, "$1***"),
        // "Bearer xyz" / "Basic xyz" / "token xyz"
        (#"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=\-]{8,}"#, "$1 ***"),
        // GitHub tokens: classic, OAuth, user-to-server, server-to-server, refresh, fine-grained.
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "gh*_***"),
        (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "github_pat_***"),
        // GitLab personal/project/group access tokens.
        (#"\bglpat-[A-Za-z0-9_\-]{20,}"#, "glpat-***"),
        // Bitbucket app passwords and Atlassian API tokens.
        (#"\bATBB[A-Za-z0-9_\-]{20,}"#, "ATBB***"),
        (#"\bATATT[A-Za-z0-9_\-=]{20,}"#, "ATATT***"),
    ].map { Rule(regex: try! NSRegularExpression(pattern: $0.0), template: $0.1) }

    public static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }

    /// Redacts the given secrets literally as well (for values we know, like the token in use).
    public static func redact(_ text: String, secrets: [String]) -> String {
        var result = redact(text)
        for secret in secrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "***")
        }
        return result
    }
}
