//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Foundation
import SimplyCoreAudio

class OutputDevices: ObservableObject {
    @Published var defaultOutputDevice: AudioDevice?
    @Published var currentSampleRate: Float64?

    private let coreAudio = SimplyCoreAudio()

    private var defaultChangesTask: Task<Void, Never>?

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let outputUpdater = OutputUpdater()
    private var timerTask: Task<Void, Never>?

    init() {
        defaultOutputDevice = coreAudio.defaultOutputDevice
        updateDefaultDeviceSampleRate()

        defaultChangesTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .defaultOutputDeviceChanged) {
                guard let self,
                      !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                }
                self.updateDefaultDeviceSampleRate()
            }
        }

        timerTask = {
            let timer = timer
            let task = Task { [weak self] in
                for await _ in timer.values {
                    guard let self,
                          !Task.isCancelled else {
                        return
                    }
                    await outputUpdater.switchLatestSampleRate(self.defaultOutputDevice)
                    let sampleRate = await self.outputUpdater.currentSampleRate
                    await MainActor.run {
                        self.currentSampleRate = sampleRate
                    }
                }
            }
            return task
        }()
    }

    deinit {
        defaultChangesTask?.cancel()
        timerTask?.cancel()
        timer.upstream.connect().cancel()
    }

    func updateDefaultDeviceSampleRate() {
        let defaultDevice = defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        Task {
            await outputUpdater.updateSampleRate(sampleRate)
            self.currentSampleRate = await outputUpdater.currentSampleRate
        }
    }
}

fileprivate actor OutputUpdater {
    var currentSampleRate: Float64?

    func switchLatestSampleRate(_ device: AudioDevice?) async {
        do {
            let musicLog = try Console.getRecentEntries()
            let cmStats = CMPlayerParser.parseMusicConsoleLogs(musicLog)

            let defaultDevice = device
            if let first = cmStats.first,
               let supported = defaultDevice?.nominalSampleRates {
                let sampleRate = Float64(first.sampleRate)
                // https://stackoverflow.com/a/65060134
                let nearest = supported.enumerated().min(by: {
                    abs($0.element - sampleRate) < abs($1.element - sampleRate)
                })
                if let nearest = nearest {
                    let nearestSampleRate = nearest.element
                    if nearestSampleRate != defaultDevice?.nominalSampleRate {
                        defaultDevice?.setNominalSampleRate(nearestSampleRate)
                        await updateSampleRate(nearestSampleRate)
                    }
                }
            }
        } catch {
            print(error)
        }
    }

    func updateSampleRate(_ sampleRate: Float64) async {
        let readableSampleRate = sampleRate / 1000
        currentSampleRate = readableSampleRate

        await MainActor.run {
            let delegate = AppDelegate.instance
            delegate?.statusItemTitle = String(format: "%.1f kHz", readableSampleRate)
        }
    }
}
