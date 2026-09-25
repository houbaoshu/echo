import Foundation
import Darwin

@main enum FixtureServer {
    static func main() {
        do {
            let server = try LoopbackModelServer()
            print(server.port)
            fflush(nil)
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let signals = [SIGTERM, SIGINT].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    do { try server.stop(); exit(0) }
                    catch {
                        FileHandle.standardError.write(Data("Fixture shutdown failed: \(error)\n".utf8))
                        exit(1)
                    }
                }
                source.resume()
                return source
            }
            withExtendedLifetime(signals) { dispatchMain() }
        } catch {
            FileHandle.standardError.write(Data("Fixture startup failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
