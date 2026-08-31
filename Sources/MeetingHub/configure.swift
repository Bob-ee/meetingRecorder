import Fluent
import FluentSQLiteDriver
import Foundation
import MeetingCore
import Vapor

func configure(_ app: Application) async throws {
    let paths = HubPaths.detect()
    try paths.ensure()
    app.hubPaths = paths
    app.hubConfig = HubConfig.load(from: paths.configFile)
    app.secrets = try Secrets.load(from: paths.masterKey)
    Log.mirrorToStderr = true

    app.databases.use(.sqlite(.file(paths.database.path)), as: .sqlite)
    app.migrations.add(CreateSchemaV1())
    app.migrations.add(AddCalendarFieldsV2())
    try await app.autoMigrate()

    ContentConfiguration.global.use(encoder: wireEncoder, for: .json)
    ContentConfiguration.global.use(decoder: jsonDecoder, for: .json)

    app.http.server.configuration.hostname = app.hubConfig.bind
    app.http.server.configuration.port = app.hubConfig.port
    app.routes.defaultMaxBodySize = "64mb"
    app.middleware.use(RemoteAllowlistMiddleware(config: app.hubConfig))

    app.eventBus = EventBus()
    app.jobRunner = JobRunner(app: app)
    try routes(app)

    app.asyncCommands.use(SetupCommand(), as: "setup")
    app.asyncCommands.use(PairCommand(), as: "pair")
    app.asyncCommands.use(TokensCommand(), as: "tokens")
    app.asyncCommands.use(ServiceCommand(), as: "service")

    // The worker only runs when serving (not during `setup`, `pair`, …).
    let args = app.environment.arguments.dropFirst()
    if args.isEmpty || args.first == "serve" {
        app.lifecycle.use(WorkerLifecycle())
    }
}

struct WorkerLifecycle: LifecycleHandler {
    func didBoot(_ app: Application) throws {
        let bus = app.eventBus
        let runner = app.jobRunner
        Task {
            await bus.startKeepalive()
            await runner.start()
        }
        app.logger.info("Meeting Hub \(HubVersion.string) — data in \(app.hubPaths.root.path), listening on \(app.hubConfig.bind):\(app.hubConfig.port)")
    }
}
