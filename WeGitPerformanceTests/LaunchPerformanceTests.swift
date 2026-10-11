import XCTest

final class LaunchPerformanceTests: XCTestCase {
    @MainActor func testColdProcessLaunchUntilResponsive() throws {
        #if DEBUG
            XCTFail("Run the WeGitPerformance scheme with the Release configuration.")
        #else
            let app = XCUIApplication()
            // Argument-domain overrides are not persisted. Keep this launch-only
            // measurement from reopening or changing any user's repository.
            app.launchArguments = [
                "-restoreRepository", "NO", "-restoreWindow", "NO", "-gitExecutable", "/usr/bin/git",
            ]
            app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            let options = XCTMeasureOptions.default
            options.iterationCount = 30
            options.invocationOptions = [.manuallyStop]
            defer { app.terminate() }
            measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
                app.launch()
                self.stopMeasuring()
                app.terminate()
            }
        #endif
    }
}
