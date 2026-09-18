import CoreMedia
import Foundation

enum SpeechResultFinalization {
    static func isFinalized(range: CMTimeRange, resultsFinalizationTime: CMTime) -> Bool {
        guard range.isValid,
            range.start.isNumeric,
            range.duration.isNumeric,
            resultsFinalizationTime.isValid,
            resultsFinalizationTime.isNumeric
        else {
            return false
        }

        return CMTimeCompare(resultsFinalizationTime, CMTimeRangeGetEnd(range)) >= 0
    }
}
