import Foundation
import LonghandKit

// §18.2's calibration, over the clusters whose names the user confirmed.
// A subcommand rather than its own tool: it reads the same pulled library, and
// keeping one command means one place to remember.
enum CalibrationCommand {

    static func run(libraryAt root: URL) -> Int32 {
        let voices = SpeakerCalibration.labelledVoices(libraryAt: root)
        guard !voices.isEmpty else {
            FileHandle.standardError.write(Data("""
            no confirmed speaker labels in \(root.path)

            A cluster counts as ground truth only once you have named it and the
            name is recorded as confirmed. A name the matcher proposed is the
            claim being calibrated, so it cannot stand in.

            """.utf8))
            return 1
        }

        let report = SpeakerCalibration.report(voices: voices)
        let people = Set(voices.map(\.person)).sorted()
        let jobs = Set(voices.map(\.jobID)).count

        func line(_ label: String, _ distribution: SpeakerCalibration.Distribution?) {
            guard let d = distribution else {
                print("  \(pad(label, 34))none")
                return
            }
            print("  \(pad(label, 34))\(d.count) pair\(d.count == 1 ? "" : "s")   "
                  + String(format: "%.4f to %.4f, mean %.4f", d.lowest, d.highest, d.mean))
        }

        print("")
        print("Labelled voices  \(voices.count) across \(jobs) recording\(jobs == 1 ? "" : "s"): \(people.joined(separator: ", "))")
        print("")
        line("same person, different takes", report.sameSpeakerAcrossRecordings)
        line("different people", report.differentSpeakers)
        line("same person, one take", report.sameSpeakerWithinOneRecording)
        print("")
        print(String(format: "Thresholds       floor %.2f, margin %.2f",
                     report.config.scoreFloor, report.config.margin))
        if let same = report.sameSpeakerAcrossRecordings {
            print("  \(report.sameSpeakerAboveFloor) of \(same.count) same-person pairs clear the floor")
        }
        if let different = report.differentSpeakers {
            print("  \(report.differentSpeakersAboveFloor) of \(different.count) different-person pairs reach it")
        }
        if let separation = report.separation {
            print(String(format: "  separation %.4f  (worst same-person minus best different-person)", separation))
        }
        print("")

        if report.sameSpeakerAcrossRecordings == nil {
            // The floor's whole job is to hold when a voice is recorded again
            // on another day. Nothing here speaks to that, and saying so is
            // more useful than printing a number that does not.
            print("""
            NOT CALIBRATED. The score floor exists to hold when the same voice is
            recorded again in another take, and there is no such pair here: every
            labelled voice comes from one recording. Enrollment copies the cluster
            centroid, so a person compared with their own take scores 1.0000 by
            construction and measures nothing.

            What would settle it: record the same people again, name the clusters
            in that take too, and re-run. The different-person figures above are
            already evidence; the same-person ones are what is missing.
            """)
        }
        return 0
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }
}
