import XCTest
@testable import HomeportCore

final class HomeportCoreTests: XCTestCase {
    func testSlugifyProducesSafeNames() {
        XCTAssertEqual(slugify("My Clean Room!"), "my-clean-room")
        XCTAssertEqual(slugify("   "), "home")
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(shellQuote("/tmp/that's fine"), "'/tmp/that'\\''s fine'")
    }

    func testSuggestedHomeNameUsesLastPathComponent() {
        XCTAssertEqual(suggestedHomeName(fromHomePath: "/tmp/marketfinch.com"), "marketfinch.com")
        XCTAssertEqual(suggestedHomeName(fromHomePath: " ~/homes/research-lab/ "), "research-lab")
        XCTAssertNil(suggestedHomeName(fromHomePath: "   "))
    }

    func testConfigOnlyCloneCopiesExpectedFiles() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "model = \"gpt\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "history".write(to: source.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        try FileCopier().createHome(destination: destination, source: source, preset: .configOnly)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("session_index.jsonl").path))
    }

    func testWorkingSetupCopiesAuthButNotSessions() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "model = \"gpt\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "history".write(to: source.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        try FileCopier().createHome(destination: destination, source: source, preset: .workingSetup)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("session_index.jsonl").path))
    }

    func testCustomCloneOptionsCopySelectedCategoriesOnly() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        try "model = \"gpt\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "history".write(to: source.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let options = CloneOptions(
            config: true,
            auth: false,
            skills: true,
            plugins: true,
            agents: false,
            prompts: false,
            rules: false,
            profiles: false,
            memories: false,
            browserSupport: false,
            sessionsAndLogs: false
        )
        try FileCopier().createHome(destination: destination, source: source, options: options)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("skills").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("plugins").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("session_index.jsonl").path))
    }

    func testLinkSafeCloneSymlinksSafeCategoriesOnly() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("browser"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("memories"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try "model = \"gpt\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "custom".write(to: source.appendingPathComponent("custom-state.json"), atomically: true, encoding: .utf8)
        try "memory".write(to: source.appendingPathComponent("memories_1.sqlite"), atomically: true, encoding: .utf8)
        try "history".write(to: source.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        try FileCopier().createHome(destination: destination, source: source, options: .full, materialization: .linkSafeCustomizations)

        XCTAssertTrue(isSymlink(destination.appendingPathComponent("skills")))
        XCTAssertTrue(isSymlink(destination.appendingPathComponent("config.toml")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("auth.json")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("browser")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("memories")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("memories_1.sqlite")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("sessions")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("session_index.jsonl")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("custom-state.json").path))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("custom-state.json")))
    }

    func testLinkAuthCloneSymlinksAuthButNotBrowserMemoriesOrHistory() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("browser"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("memories"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try "model = \"gpt\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "memory".write(to: source.appendingPathComponent("memories_1.sqlite"), atomically: true, encoding: .utf8)
        try "history".write(to: source.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        try FileCopier().createHome(destination: destination, source: source, options: .full, materialization: .linkSafeCustomizationsAndAuth)

        XCTAssertTrue(isSymlink(destination.appendingPathComponent("config.toml")))
        XCTAssertTrue(isSymlink(destination.appendingPathComponent("auth.json")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("browser")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("memories")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("memories_1.sqlite")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("sessions")))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("session_index.jsonl")))
    }

    func testClonePoliciesAllowMixedSkipCopyAndLink() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        try "model = \"gpt\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let policies = ClonePolicies(
            config: .copy,
            auth: .link,
            skills: .link,
            plugins: .skip,
            agents: .skip,
            prompts: .skip,
            rules: .skip,
            profiles: .skip,
            memories: .skip,
            browserSupport: .skip,
            sessionsAndLogs: .skip
        )
        try FileCopier().createHome(destination: destination, source: source, policies: policies)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
        XCTAssertFalse(isSymlink(destination.appendingPathComponent("config.toml")))
        XCTAssertTrue(isSymlink(destination.appendingPathComponent("auth.json")))
        XCTAssertTrue(isSymlink(destination.appendingPathComponent("skills")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("plugins").path))
    }

    func testCloneCategoryMetadataDrivesDisplayedAndCopiedPaths() throws {
        for category in CloneCategory.allCases {
            for path in category.paths {
                XCTAssertTrue(category.pathSummary.contains(path), "\(category.rawValue) summary omitted \(path)")
            }

            let root = try makeTempRoot()
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            for path in category.paths {
                try path.write(to: source.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }

            var policies = ClonePolicies.empty
            policies[category] = .copy
            try FileCopier().createHome(destination: destination, source: source, policies: policies)

            for path in category.paths {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path),
                    "\(category.rawValue) did not copy \(path)"
                )
            }
        }
    }

    func testFileCopierRemovesDestinationAfterMaterializationFailure() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let unreadableConfig = source.appendingPathComponent("config.toml")
        try "secret".write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "model = \"gpt\"".write(to: unreadableConfig, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableConfig.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableConfig.path)
        }

        XCTAssertThrowsError(try FileCopier().createHome(destination: destination, source: source, options: .workingSetup))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testLinkSafeCloneResolvesSourceSymlinkOneHop() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let realSkills = root.appendingPathComponent("real-skills")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("skills"), withDestinationURL: realSkills)

        let options = CloneOptions(
            config: false,
            auth: false,
            skills: true,
            plugins: false,
            agents: false,
            prompts: false,
            rules: false,
            profiles: false,
            memories: false,
            browserSupport: false,
            sessionsAndLogs: false
        )
        try FileCopier().createHome(destination: destination, source: source, options: options, materialization: .linkSafeCustomizations)

        let linkedTarget = try symlinkTarget(destination.appendingPathComponent("skills"))
        XCTAssertEqual(linkedTarget.standardizedFileURL.path, realSkills.standardizedFileURL.path)
    }

    func testDeletingSymlinkedHomeDoesNotDeleteSourceContent() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let mainSkills = root.appendingPathComponent(".codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: mainSkills, withIntermediateDirectories: true)
        try "skill".write(to: mainSkills.appendingPathComponent("skill.md"), atomically: true, encoding: .utf8)

        let options = CloneOptions(
            config: false,
            auth: false,
            skills: true,
            plugins: false,
            agents: false,
            prompts: false,
            rules: false,
            profiles: false,
            memories: false,
            browserSupport: false,
            sessionsAndLogs: false
        )
        let home = try service.clone(
            name: "Linked Skills",
            preset: .workingSetup,
            options: options,
            sourceSelector: "main",
            materialization: .linkSafeCustomizations
        )
        XCTAssertTrue(isSymlink(URL(fileURLWithPath: home.homePath).appendingPathComponent("skills")))

        _ = try service.deleteHome(id: home.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: mainSkills.appendingPathComponent("skill.md").path))
    }

    func testManagedHomeCanBeCloneSource() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let mainConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: mainConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"template\"".write(to: mainConfig, atomically: true, encoding: .utf8)

        let template = try service.clone(name: "Template Home", preset: .configOnly, options: .configOnly)
        let clone = try service.clone(
            name: "From Template",
            preset: .configOnly,
            options: .configOnly,
            sourceSelector: template.slug,
            materialization: .linkSafeCustomizations
        )

        XCTAssertEqual(clone.sourceHomePath, template.homePath)
        XCTAssertTrue(isSymlink(URL(fileURLWithPath: clone.homePath).appendingPathComponent("config.toml")))
    }

    func testClonePersistsExactPolicies() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let mainHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: mainHome.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try "secret".write(to: mainHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let policies = ClonePolicies(
            config: .skip,
            auth: .link,
            skills: .copy,
            plugins: .skip,
            agents: .skip,
            prompts: .skip,
            rules: .skip,
            profiles: .skip,
            memories: .skip,
            browserSupport: .skip,
            sessionsAndLogs: .skip
        )
        let home = try service.clone(name: "Mixed Policy", preset: .workingSetup, policies: policies, sourceSelector: "main")
        let saved = try XCTUnwrap(try service.loadState().homes.first { $0.id == home.id })

        XCTAssertEqual(saved.clonePolicies, policies)
        XCTAssertEqual(saved.clonePolicies?.summary, "Link auth • Copy skills")
    }

    func testInvalidCloneSourceThrows() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))

        XCTAssertThrowsError(try service.clone(
            name: "Missing Source",
            preset: .configOnly,
            options: .configOnly,
            sourceSelector: "missing-source",
            materialization: .linkSafeCustomizations
        ))
    }

    func testTerminalCommandUsesPerProcessCodexHome() {
        let home = CodexHome(
            name: "Temp",
            slug: "temp",
            kind: .temporary,
            homePath: "/tmp/home port",
            profilePath: "/tmp/profile"
        )
        let command = Launcher().terminalShellCommand(home: home, workspace: "/tmp/work space")
        XCTAssertEqual(command, "cd '/tmp/work space'; CODEX_HOME='/tmp/home port' codex")
    }

    func testTerminalCommandCanEnableBrowserUseLocalTestingMode() {
        let home = CodexHome(
            name: "Temp",
            slug: "temp",
            kind: .temporary,
            homePath: "/tmp/home port",
            profilePath: "/tmp/profile"
        )
        let command = Launcher().terminalShellCommand(
            home: home,
            workspace: "/tmp/work space",
            browserUseLocalTestingMode: true
        )
        XCTAssertEqual(
            command,
            "cd '/tmp/work space'; CODEX_HOME='/tmp/home port' BROWSER_USE_SECURITY_MODE=disabled-for-local-testing codex"
        )
    }

    func testBrowserUseLocalTestingModeEnvironmentHelper() {
        var environment = ["BROWSER_USE_SECURITY_MODE": "existing", "OTHER": "1"]

        applyBrowserUseLocalTestingMode(true, to: &environment)
        XCTAssertEqual(environment["BROWSER_USE_SECURITY_MODE"], "disabled-for-local-testing")
        XCTAssertEqual(environment["OTHER"], "1")

        applyBrowserUseLocalTestingMode(false, to: &environment)
        XCTAssertNil(environment["BROWSER_USE_SECURITY_MODE"])
        XCTAssertEqual(environment["OTHER"], "1")
    }

    func testBrowserUseLocalTestingModeUpdatesNodeReplConfig() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("config.toml")
        try """
        model = "gpt-5"

        [mcp_servers.node_repl.env]
        NODE_REPL_NODE_PATH = "/Applications/Codex.app/Contents/Resources/cua_node/bin/node"
        """.write(to: config, atomically: true, encoding: .utf8)

        try setBrowserUseLocalTestingModeInConfig(in: home, isEnabled: true)
        try setBrowserUseLocalTestingModeInConfig(in: home, isEnabled: true)

        var text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "BROWSER_USE_SECURITY_MODE").count, 2)
        XCTAssertTrue(text.contains("[mcp_servers.node_repl.env]\nBROWSER_USE_SECURITY_MODE = \"disabled-for-local-testing\"\nNODE_REPL_NODE_PATH"))

        try setBrowserUseLocalTestingModeInConfig(in: home, isEnabled: false)

        text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertFalse(text.contains("BROWSER_USE_SECURITY_MODE"))
        XCTAssertTrue(text.contains("NODE_REPL_NODE_PATH"))
    }

    func testBrowserUseLocalTestingModeCreatesNodeReplConfigTable() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)

        try setBrowserUseLocalTestingModeInConfig(in: home, isEnabled: true)

        let text = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertEqual(
            text,
            """
            [mcp_servers.node_repl.env]
            BROWSER_USE_SECURITY_MODE = "disabled-for-local-testing"

            """
        )
    }

    func testShimDesktopEnvironmentEnablesBrowserCompatibleDevLaunch() {
        let arguments = shimBrowserCompatibleDesktopEnvironmentArguments(environment: [
            "NO_PROXY": "localhost,127.0.0.1",
            "no_proxy": ""
        ])

        XCTAssertEqual(Array(arguments.prefix(2)), ["--env", "BUILD_FLAVOR=dev"])
        XCTAssertTrue(arguments.contains("--env"))
        XCTAssertTrue(arguments.contains("CODEX_ELECTRON_DESKTOP_FEATURE_OVERRIDES={\"browserPane\":true,\"inAppBrowserUse\":true,\"inAppBrowserUseAllowed\":true,\"multiBrowserTabs\":true}"))
        XCTAssertTrue(arguments.contains("NO_PROXY=localhost,127.0.0.1"))
        XCTAssertFalse(arguments.contains("no_proxy="))
    }

    func testCachedBrowserSkillPatchAddsStatelessRedditScreenshotSmoke() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex-home", isDirectory: true)
        let skill = home
            .appendingPathComponent("plugins/cache/openai-bundled/browser/26.623.101652/skills/control-in-app-browser", isDirectory: true)
            .appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        # Browser

        Initialize the runtime once per fresh Node session.
        """.write(to: skill, atomically: true, encoding: .utf8)

        try patchCachedBrowserSkillForStatelessIAB(in: home)
        try patchCachedBrowserSkillForStatelessIAB(in: home)

        let patched = try String(contentsOf: skill, encoding: .utf8)
        XCTAssertEqual(patched.components(separatedBy: statelessIABWorkflowMarker).count, 2)
        XCTAssertTrue(patched.contains("Do not rely on `browser` or `tab` bindings from an earlier JavaScript call."))
        XCTAssertTrue(patched.contains("await (await browser.capabilities.get(\"visibility\")).set(true);"))
        XCTAssertTrue(patched.contains("await tab.goto(\"https://www.reddit.com/\");"))
        XCTAssertTrue(patched.contains("await nodeRepl.emitImage(await tab.screenshot());"))
        XCTAssertTrue(patched.contains("browser.user.claimTab(tab)"))
    }

    func testCachedBrowserSkillPatchUpgradesLegacyStatelessBlock() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex-home", isDirectory: true)
        let skill = home
            .appendingPathComponent("plugins/cache/openai-bundled/browser/26.623.101652/skills/control-in-app-browser", isDirectory: true)
            .appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        # Browser

        ## Stateless In-App Browser Calls

        const browser = await agent.browsers.get("iab");
        const tab = await browser.tabs.new();
        await tab.goto("https://www.reddit.com/");
        """.write(to: skill, atomically: true, encoding: .utf8)

        try patchCachedBrowserSkillForStatelessIAB(in: home)

        let patched = try String(contentsOf: skill, encoding: .utf8)
        XCTAssertEqual(patched.components(separatedBy: statelessIABWorkflowMarker).count, 2)
        XCTAssertTrue(patched.contains("await (await browser.capabilities.get(\"visibility\")).set(true);"))
        XCTAssertTrue(patched.contains(statelessIABWorkflowEndMarker))
    }

    func testShimLaunchEnablesBundledBrowserPluginsInHomeConfig() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("config.toml")
        try """
        # >>> codex-shim managed >>>
        model = "ollama-glm-5-2-cloud"
        model_provider = "codex_shim"
        # <<< codex-shim managed <<<
        """.write(to: config, atomically: true, encoding: .utf8)

        try enableBundledBrowserPluginsForShim(in: home)
        try enableBundledBrowserPluginsForShim(in: home)

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("model_provider = \"codex_shim\""))
        XCTAssertEqual(text.components(separatedBy: shimBundledBrowserPluginsBegin).count, 2)
        XCTAssertTrue(text.contains("[plugins.\"browser@openai-bundled\"]\nenabled = true"))
        XCTAssertTrue(text.contains("[plugins.\"chrome@openai-bundled\"]\nenabled = true"))
        XCTAssertTrue(text.contains("[plugins.\"computer-use@openai-bundled\"]\nenabled = true"))
    }

    func testDefaultInstallEnablesBundledComputerUsePluginInMainConfig() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("config.toml")
        try "model = \"gpt-5\"\n".write(to: config, atomically: true, encoding: .utf8)

        try ComputerUseDefaults.applyInstallSupport(in: home, isEnabled: true)
        try ComputerUseDefaults.applyInstallSupport(in: home, isEnabled: true)

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("model = \"gpt-5\""))
        XCTAssertEqual(text.components(separatedBy: computerUseDefaultInstallBegin).count, 2)
        XCTAssertTrue(text.contains("[plugins.\"computer-use@openai-bundled\"]\nenabled = true"))
    }

    func testDefaultInstallDoesNotDuplicateExistingComputerUsePluginTable() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("config.toml")
        try """
        [plugins."computer-use@openai-bundled"]
        enabled = true
        """.write(to: config, atomically: true, encoding: .utf8)

        try ComputerUseDefaults.applyInstallSupport(in: home, isEnabled: true)

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "[plugins.\"computer-use@openai-bundled\"]").count, 2)
        XCTAssertFalse(text.contains(computerUseDefaultInstallBegin))
    }

    func testCachedComputerUseSkillPatchAddsForbiddenTargetsInstructions() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        let skill = home
            .appendingPathComponent("plugins/cache/openai-bundled/computer-use/1.0.857/skills/computer-use", isDirectory: true)
            .appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        # Computer Use

        Use for desktop app control.
        """.write(to: skill, atomically: true, encoding: .utf8)

        try ComputerUseDefaults.applyInstallSupport(in: home, isEnabled: true)
        try ComputerUseDefaults.applyInstallSupport(in: home, isEnabled: true)

        let patched = try String(contentsOf: skill, encoding: .utf8)
        XCTAssertEqual(patched.components(separatedBy: forbiddenComputerUseTargetsMarker).count, 2)
        XCTAssertTrue(patched.contains("defaults read -g ComputerUseAllowForbiddenTargets"))
        XCTAssertTrue(patched.contains("defaults write -g ComputerUseAllowForbiddenTargets -bool YES"))
        XCTAssertTrue(patched.contains(forbiddenComputerUseTargetsEndMarker))
    }

    func testDiagnosticsCountsSessions() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "a\nb\n".write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let diagnostics = Diagnostics(paths: HomeportPaths(homeDirectory: root))
        XCTAssertEqual(diagnostics.sessionCount(in: home), 2)
    }

    func testDiagnosticsReportsStoredChatGPTAuthMetadata() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let auth = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "id_token": "header.eyJlbWFpbCI6InRha0BleGFtcGxlLmNvbSJ9.signature",
            "access_token": "redacted",
            "account_id": "12345678-1234-1234-1234-123456789abc"
          }
        }
        """
        try auth.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let status = Diagnostics(paths: HomeportPaths(homeDirectory: root)).authStatus(in: home, includeCLIStatus: false)

        XCTAssertFalse(status.isLoggedIn)
        XCTAssertTrue(status.hasStoredCredentials)
        XCTAssertEqual(status.mode, "chatgpt")
        XCTAssertEqual(status.accountLabel, "tak@example.com")
        XCTAssertEqual(status.usageSummary, "Usage unavailable")
    }

    func testDiagnosticsReportsMissingAuth() throws {
        let root = try makeTempRoot()

        let report = Diagnostics(paths: HomeportPaths(homeDirectory: root)).report()

        XCTAssertFalse(report.authStatus.isLoggedIn)
        XCTAssertNil(report.authStatus.accountLabel)
    }

    func testDiagnosticsDoesNotTreatAccountIDAloneAsLoggedIn() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let auth = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "account_id": "12345678-1234-1234-1234-123456789abc"
          }
        }
        """
        try auth.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let status = Diagnostics(paths: HomeportPaths(homeDirectory: root)).authStatus(in: home, includeCLIStatus: false)

        XCTAssertFalse(status.isLoggedIn)
        XCTAssertFalse(status.hasStoredCredentials)
        XCTAssertEqual(status.accountLabel, "account 12345678")
    }

    func testDiagnosticsReportsAuthForSpecificHome() throws {
        let root = try makeTempRoot()
        let mainHome = root.appendingPathComponent(".codex")
        let cloneHome = root.appendingPathComponent(".codex-homes/clone")
        try FileManager.default.createDirectory(at: mainHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloneHome, withIntermediateDirectories: true)
        let auth = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "id_token": "header.eyJlbWFpbCI6ImNsb25lQGV4YW1wbGUuY29tIn0.signature",
            "refresh_token": "redacted"
          }
        }
        """
        try auth.write(to: cloneHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        let diagnostics = Diagnostics(paths: HomeportPaths(homeDirectory: root))

        XCTAssertFalse(diagnostics.authStatus(in: mainHome, includeCLIStatus: false).hasStoredCredentials)
        XCTAssertFalse(diagnostics.authStatus(in: cloneHome, includeCLIStatus: false).isLoggedIn)
        XCTAssertTrue(diagnostics.authStatus(in: cloneHome, includeCLIStatus: false).hasStoredCredentials)
        XCTAssertEqual(diagnostics.authStatus(in: cloneHome, includeCLIStatus: false).accountLabel, "clone@example.com")
    }

    func testCannotDeleteMainHome() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))

        let state = try service.loadState()
        let main = try XCTUnwrap(state.homes.first(where: { $0.kind == .main }))

        XCTAssertThrowsError(try service.deleteHome(id: main.id))
    }

    func testRenameManagedHomeUpdatesNameAndSlug() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let home = try service.createCleanRoom(name: "Old Name")
        let originalHomePath = home.homePath
        let originalProfilePath = try XCTUnwrap(home.profilePath)
        var stateWithRecent = try service.loadState()
        stateWithRecent.instances.append(LaunchedInstance(
            homeID: home.id,
            homeName: home.name,
            homePath: home.homePath,
            profilePath: home.profilePath,
            target: .desktop,
            pid: nil,
            workspacePath: nil,
            terminalApp: nil
        ))
        try service.saveState(stateWithRecent)

        try service.renameHome(id: home.id, name: "New Name")

        let state = try service.loadState()
        let renamed = try XCTUnwrap(state.homes.first(where: { $0.id == home.id }))
        let recent = try XCTUnwrap(state.instances.first(where: { $0.homeID == home.id }))
        XCTAssertEqual(renamed.name, "New Name")
        XCTAssertEqual(renamed.slug, "new-name")
        XCTAssertEqual(renamed.homePath, originalHomePath)
        XCTAssertEqual(renamed.profilePath, originalProfilePath)
        XCTAssertEqual(recent.homeName, "New Name")
        XCTAssertEqual(recent.homePath, originalHomePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalHomePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalProfilePath))
    }

    func testRenameManagedHomeCanMoveHomeAndProfileFolders() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let template = try service.createCleanRoom(name: "Template")
        let clone = try service.clone(
            name: "From Template",
            preset: .configOnly,
            options: .configOnly,
            sourceSelector: template.slug,
            materialization: .copy
        )
        let oldHomePath = template.homePath
        let oldProfilePath = try XCTUnwrap(template.profilePath)
        try "profile".write(to: URL(fileURLWithPath: oldProfilePath).appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

        try service.renameHome(id: template.id, name: "Renamed Template", moveFolders: true)

        let state = try service.loadState()
        let renamed = try XCTUnwrap(state.homes.first(where: { $0.id == template.id }))
        let updatedClone = try XCTUnwrap(state.homes.first(where: { $0.id == clone.id }))
        XCTAssertEqual(renamed.name, "Renamed Template")
        XCTAssertEqual(renamed.slug, "renamed-template")
        XCTAssertEqual(URL(fileURLWithPath: renamed.homePath).lastPathComponent, "renamed-template")
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(renamed.profilePath)).lastPathComponent, "renamed-template")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldHomePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldProfilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.homePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: try XCTUnwrap(renamed.profilePath)).appendingPathComponent("marker.txt").path))
        XCTAssertEqual(updatedClone.sourceHomePath, renamed.homePath)
    }

    func testRenameManagedHomeMoveRefusesFolderConflict() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let home = try service.createCleanRoom(name: "Old Name")
        let conflictingHome = root.appendingPathComponent(".codex-homes/new-name", isDirectory: true)
        try FileManager.default.createDirectory(at: conflictingHome, withIntermediateDirectories: true)
        let oldHomePath = home.homePath
        let oldProfilePath = try XCTUnwrap(home.profilePath)

        XCTAssertThrowsError(try service.renameHome(id: home.id, name: "New Name", moveFolders: true)) { error in
            XCTAssertEqual(error as? HomeportError, HomeportError.homeAlreadyExists(conflictingHome.path))
        }

        let saved = try XCTUnwrap(try service.loadState().homes.first(where: { $0.id == home.id }))
        XCTAssertEqual(saved.name, "Old Name")
        XCTAssertEqual(saved.slug, "old-name")
        XCTAssertEqual(saved.homePath, oldHomePath)
        XCTAssertEqual(saved.profilePath, oldProfilePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldHomePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldProfilePath))
    }

    func testCreateCleanRoomCanUseCustomHomePath() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let customHome = root.appendingPathComponent("custom-homes/blank", isDirectory: true)

        let home = try service.createCleanRoom(name: "Blank", homePath: customHome.path)

        XCTAssertEqual(home.homePath, customHome.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: customHome.path))
        XCTAssertEqual(try service.loadState().homes.first(where: { $0.id == home.id })?.homePath, customHome.standardizedFileURL.path)
    }

    func testCreateCleanRoomWithPathCanInferName() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let customHome = root.appendingPathComponent("marketfinch.com", isDirectory: true)

        let home = try service.createCleanRoom(homePath: customHome.path)

        XCTAssertEqual(home.name, "marketfinch.com")
        XCTAssertEqual(home.slug, "marketfinch-com")
    }

    func testCloneCanUseCustomHomePath() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let mainConfig = root.appendingPathComponent(".codex/config.toml")
        let customHome = root.appendingPathComponent("custom-homes/clone", isDirectory: true)
        try FileManager.default.createDirectory(at: mainConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"template\"".write(to: mainConfig, atomically: true, encoding: .utf8)

        let home = try service.clone(
            name: "Custom Clone",
            preset: .configOnly,
            policies: .configOnly,
            sourceSelector: "main",
            homePath: customHome.path
        )

        XCTAssertEqual(home.homePath, customHome.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: customHome.appendingPathComponent("config.toml").path))
    }

    func testChangeHomePathCanMoveExistingHomeAndUpdateReferences() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let template = try service.createCleanRoom(name: "Template")
        let clone = try service.clone(
            name: "From Template",
            preset: .configOnly,
            options: .configOnly,
            sourceSelector: template.slug,
            materialization: .copy
        )
        var stateWithRecent = try service.loadState()
        stateWithRecent.instances.append(LaunchedInstance(
            homeID: template.id,
            homeName: template.name,
            homePath: template.homePath,
            profilePath: template.profilePath,
            target: .desktop,
            pid: nil,
            workspacePath: nil,
            terminalApp: nil
        ))
        try service.saveState(stateWithRecent)
        let oldPath = template.homePath
        let newHome = root.appendingPathComponent("custom-homes/template", isDirectory: true)

        try service.changeHomePath(id: template.id, homePath: newHome.path, moveExisting: true)

        let state = try service.loadState()
        let moved = try XCTUnwrap(state.homes.first(where: { $0.id == template.id }))
        let updatedClone = try XCTUnwrap(state.homes.first(where: { $0.id == clone.id }))
        let updatedRecent = try XCTUnwrap(state.instances.first(where: { $0.homeID == template.id }))
        XCTAssertEqual(moved.homePath, newHome.standardizedFileURL.path)
        XCTAssertEqual(updatedClone.sourceHomePath, newHome.standardizedFileURL.path)
        XCTAssertEqual(updatedRecent.homePath, newHome.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newHome.path))
    }

    func testChangeHomePathCanAdoptExistingDirectoryWithoutMovingOldHome() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let home = try service.createCleanRoom(name: "Adoptable")
        let oldPath = home.homePath
        let existingHome = root.appendingPathComponent("existing-home", isDirectory: true)
        try FileManager.default.createDirectory(at: existingHome, withIntermediateDirectories: true)

        try service.changeHomePath(id: home.id, homePath: existingHome.path)

        let saved = try XCTUnwrap(try service.loadState().homes.first(where: { $0.id == home.id }))
        XCTAssertEqual(saved.homePath, existingHome.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPath))
    }

    func testPinningManagedHomePersists() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let home = try service.createCleanRoom(name: "Pinned Home")

        try service.setHomePinned(id: home.id, pinned: true)
        XCTAssertEqual(try service.loadState().pinnedHomeIDs, [home.id])

        try service.setHomePinned(id: home.id, pinned: false)
        XCTAssertTrue(try service.loadState().pinnedHomeIDs.isEmpty)
    }

    func testModelRoutingPersistsPerHome() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let home = try service.createCleanRoom(name: "Routed Home")

        let routing = ModelRoutingConfig(isEnabled: true, providers: ["codex", "ollama"], allowAPIKeyPresets: true)
        try service.setModelRouting(id: home.id, routing: routing)
        let saved = try XCTUnwrap(try service.loadState().homes.first(where: { $0.id == home.id }))
        XCTAssertEqual(saved.modelRouting, routing)

        try service.setModelRouting(id: home.id, routing: nil)
        let cleared = try XCTUnwrap(try service.loadState().homes.first(where: { $0.id == home.id }))
        XCTAssertNil(cleared.modelRouting)
    }

    func testModelRoutingDecodeOlderHomeDefaultsToNil() throws {
        let data = """
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "name": "Plain Home",
          "slug": "plain-home",
          "kind": "cleanRoom",
          "homePath": "/tmp/home",
          "profilePath": "/tmp/profile",
          "isTemporary": false
        }
        """.data(using: .utf8)!

        let home = try JSONDecoder().decode(CodexHome.self, from: data)

        XCTAssertNil(home.modelRouting)
    }

    func testMainHomeHasStableIDAcrossFreshLoads() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))

        let first = try XCTUnwrap(try service.loadState().homes.first(where: { $0.kind == .main }))
        let second = try XCTUnwrap(try service.loadState().homes.first(where: { $0.kind == .main }))

        XCTAssertEqual(first.id, HomeportStore.mainHomeID)
        XCTAssertEqual(second.id, first.id)
    }

    func testPinningMainHomeFromFreshStatePersists() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let main = try XCTUnwrap(try service.loadState().homes.first(where: { $0.kind == .main }))

        try service.setHomePinned(id: main.id, pinned: true)
        XCTAssertEqual(try service.loadState().pinnedHomeIDs, [main.id])

        try service.setHomePinned(id: main.id, pinned: false)
        XCTAssertTrue(try service.loadState().pinnedHomeIDs.isEmpty)
    }

    func testPreferencesDecodeOlderStateWithUpdaterDefaults() throws {
        let data = """
        {
          "defaultLaunchTarget": "desktop",
          "defaultClonePreset": "working-setup",
          "cloneOptions": {
            "config": true,
            "auth": true,
            "skills": true,
            "plugins": true,
            "agents": true,
            "prompts": true,
            "rules": true,
            "profiles": true,
            "memories": true,
            "browserSupport": true,
            "sessionsAndLogs": false,
            "everything": false
          },
          "launchTemporaryByDefault": false,
          "onboardEnablesAutostart": true,
          "installAppByDefault": true
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(HomeportPreferences.self, from: data)

        XCTAssertTrue(preferences.autoUpdateChecksEnabled)
        XCTAssertFalse(preferences.autoInstallUpdates)
        XCTAssertEqual(preferences.updateCheckInterval, .daily)
        XCTAssertEqual(preferences.cloneMaterialization, .copy)
        XCTAssertEqual(preferences.cloneSourceSelector, "main")
        XCTAssertEqual(preferences.clonePolicies, ClonePolicies(options: preferences.cloneOptions, materialization: .copy))
        XCTAssertTrue(preferences.allowForbiddenComputerUseTargetsByDefault)
        XCTAssertFalse(preferences.browserUseLocalTestingMode)
        XCTAssertNil(preferences.lastClonePolicies)
    }

    func testCodexHomeDecodeOlderCloneMetadataBuildsPolicies() throws {
        let data = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Linked Legacy",
          "slug": "linked-legacy",
          "kind": "clone",
          "homePath": "/tmp/home",
          "profilePath": "/tmp/profile",
          "sourceHomePath": "/tmp/source",
          "clonePreset": "config-only",
          "cloneMaterialization": "linkSafeCustomizations",
          "isTemporary": false
        }
        """.data(using: .utf8)!

        let home = try JSONDecoder().decode(CodexHome.self, from: data)

        XCTAssertEqual(home.clonePolicies, ClonePolicies(options: .configOnly, materialization: .linkSafeCustomizations))
    }

    func testVersionComparisonHandlesSemverLikeStrings() {
        XCTAssertEqual(compareVersions("0.4.0", "0.3.9"), .orderedDescending)
        XCTAssertEqual(compareVersions("v0.3.0", "0.3.0"), .orderedSame)
        XCTAssertEqual(compareVersions("0.3.0", "0.3.1"), .orderedAscending)
    }

    func testUpdaterCheckScheduleUsesSavedInterval() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        var state = try service.loadState()
        let now = Date()
        state.preferences.autoUpdateChecksEnabled = true
        state.preferences.updateCheckInterval = .daily
        state.updater.lastCheckedAt = now.addingTimeInterval(-60 * 60)
        try service.saveState(state)

        XCTAssertFalse(try service.shouldCheckForUpdates(now: now))

        state.updater.lastCheckedAt = now.addingTimeInterval(-60 * 60 * 25)
        try service.saveState(state)

        XCTAssertTrue(try service.shouldCheckForUpdates(now: now))
    }

    func testUpdaterAvailabilityStopsAfterInstallStarts() {
        let available = UpdaterState(latestVersion: "9.9.9")
        XCTAssertTrue(available.updateAvailable(currentVersion: "0.3.0"))

        let installing = UpdaterState(latestVersion: "9.9.9", installStartedAt: Date())
        XCTAssertFalse(installing.updateAvailable(currentVersion: "0.3.0"))
    }

    func testDevChannelUsesSeparateHomeportStateAndManagedHomes() throws {
        let root = try makeTempRoot()
        let live = HomeportPaths(homeDirectory: root, channel: .live)
        let dev = HomeportPaths(homeDirectory: root, channel: .dev)

        XCTAssertEqual(live.appSupportDirectory.lastPathComponent, "CodexMultihome")
        XCTAssertEqual(dev.appSupportDirectory.lastPathComponent, "CodexMultihomeDev")
        XCTAssertEqual(live.legacyAppSupportDirectory.lastPathComponent, "CodexHomeport")
        XCTAssertEqual(dev.legacyAppSupportDirectory.lastPathComponent, "CodexHomeportDev")
        XCTAssertEqual(live.managedHomesDirectory.lastPathComponent, ".codex-homes")
        XCTAssertEqual(dev.managedHomesDirectory.lastPathComponent, ".codex-homes-dev")
        XCTAssertNotEqual(live.stateFile.path, dev.stateFile.path)
    }

    func testLoadMigratesLegacyHomeportStateDirectory() throws {
        let root = try makeTempRoot()
        let paths = HomeportPaths(homeDirectory: root)
        try FileManager.default.createDirectory(at: paths.legacyAppSupportDirectory, withIntermediateDirectories: true)
        let legacyState = HomeportState(pinnedHomeIDs: [HomeportStore.mainHomeID])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacyState).write(to: paths.legacyStateFile)

        let state = try HomeportService(paths: paths).loadState()

        XCTAssertEqual(state.pinnedHomeIDs, [HomeportStore.mainHomeID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.stateFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyAppSupportDirectory.path))
    }

    func testLoadMergesLegacyHomeportStateWhenCurrentStateAlreadyExists() throws {
        let root = try makeTempRoot()
        let paths = HomeportPaths(homeDirectory: root)
        let currentHome = CodexHome(
            name: "Current Home",
            slug: "current-home",
            kind: .clone,
            homePath: root.appendingPathComponent(".codex-homes/current-home").path,
            profilePath: paths.profilesDirectory.appendingPathComponent("current-home").path
        )
        let legacyHome = CodexHome(
            name: "Legacy Home",
            slug: "legacy-home",
            kind: .clone,
            homePath: root.appendingPathComponent(".codex-homes/legacy-home").path,
            profilePath: paths.legacyAppSupportDirectory.appendingPathComponent("Profiles/legacy-home").path
        )
        let legacyInstance = LaunchedInstance(
            homeID: legacyHome.id,
            homeName: legacyHome.name,
            homePath: legacyHome.homePath,
            profilePath: legacyHome.profilePath,
            target: .desktop,
            pid: nil,
            workspacePath: "/",
            terminalApp: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: paths.appSupportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.legacyAppSupportDirectory, withIntermediateDirectories: true)
        try encoder.encode(HomeportState(homes: [currentHome])).write(to: paths.stateFile)
        try encoder.encode(HomeportState(
            homes: [legacyHome],
            instances: [legacyInstance],
            pinnedHomeIDs: [legacyHome.id]
        )).write(to: paths.legacyStateFile)

        let state = try HomeportService(paths: paths).loadState()

        XCTAssertNotNil(state.homes.first(where: { $0.id == currentHome.id }))
        XCTAssertNotNil(state.homes.first(where: { $0.id == legacyHome.id }))
        XCTAssertNotNil(state.instances.first(where: { $0.id == legacyInstance.id }))
        XCTAssertTrue(state.pinnedHomeIDs.contains(legacyHome.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.legacyStateFile.path))
    }

    func testChannelReadsEnvironmentBeforeBundleDefault() {
        XCTAssertEqual(HomeportChannel.current(environment: ["HOMEPORT_CHANNEL": "dev"], bundle: .main), .dev)
        XCTAssertEqual(HomeportChannel.current(environment: ["HOMEPORT_CHANNEL": "live"], bundle: .main), .live)
    }

    func testCodexDesktopAppDiscoveryUsesBundleIdentityAndExecutableMetadata() throws {
        let root = try makeTempRoot()
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let desktopApp = applications.appendingPathComponent("Renamed Codex.app", isDirectory: true)
        let executable = desktopApp
            .appendingPathComponent("Contents/MacOS/NotCodex", isDirectory: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.openai.codex</string>
        <key>CFBundleExecutable</key><string>NotCodex</string>
        <key>CFBundleDisplayName</key><string>Codex Desktop</string>
        </dict></plist>
        """
        try info.write(
            to: desktopApp.appendingPathComponent("Contents/Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        let paths = HomeportPaths(homeDirectory: root)

        let discovered = try XCTUnwrap(paths.codexDesktopApp)
        XCTAssertEqual(discovered.bundleURL.lastPathComponent, "Renamed Codex.app")
        XCTAssertEqual(discovered.executableURL.lastPathComponent, "NotCodex")
        XCTAssertEqual(discovered.displayName, "Codex Desktop")
        XCTAssertEqual(paths.codexAppBundle.lastPathComponent, "Renamed Codex.app")
        XCTAssertEqual(paths.codexAppExecutable.lastPathComponent, "NotCodex")
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func symlinkTarget(_ url: URL) throws -> URL {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        if target.hasPrefix("/") {
            return URL(fileURLWithPath: target)
        }
        return url.deletingLastPathComponent().appendingPathComponent(target)
    }
}
