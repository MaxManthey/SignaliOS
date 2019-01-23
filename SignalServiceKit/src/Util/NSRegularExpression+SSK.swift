//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
public extension NSRegularExpression {

    @objc
    public func hasMatch(input: String) -> Bool {
        return self.firstMatch(in: input, options: [], range: NSRange(location: 0, length: input.utf16.count)) != nil
    }

    @objc
    public class func parseFirstMatch(pattern: String,
                                      text: String) -> String? {
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: text,
                                               options: [],
                                               range: NSRange(location: 0, length: text.count)) else {
                                                return nil
            }
            let matchRange = match.range(at: 1)
            guard let textRange = Range(matchRange, in: text) else {
                owsFailDebug("Invalid match.")
                return nil
            }
            let substring = String(text[textRange])
            return substring
        } catch {
            Logger.error("Error: \(error)")
            return nil
        }
    }
}