require "open3"
require "fileutils"
require "digest"
require "zlib"

module LLMProxy
  module Codex
    RUNTIME_DIR = File.expand_path("../../.codex-shim", __dir__)
    APP_ASAR = "/Applications/Codex.app/Contents/Resources/app.asar"

    BACKUP_DIR = File.join(RUNTIME_DIR, "backups")

    class << self
      def backup
        version = codex_version
        backup_path = File.join(BACKUP_DIR, version[:build])
        FileUtils.mkdir_p(backup_path)

        dest = File.join(backup_path, "app.asar.gz")
        unless File.exist?(dest)
          data = File.read(APP_ASAR, mode: "rb")
          Zlib::GzipWriter.open(dest) { |gz| gz.write(data) }
          File.write(File.join(backup_path, "version.txt"), "#{version[:short]} (build #{version[:build]})\n")
          File.write(File.join(backup_path, "asar.sha256"), Digest::SHA256.hexdigest(data) + "\n")
          size_mb = (data.bytesize.to_f / 1024 / 1024).round(1)
          puts "✅ Backed up Codex #{version[:short]} (#{version[:build]}) — #{size_mb}MB"
        else
          puts "ℹ️  Codex #{version[:short]} (#{version[:build]}) already backed up"
        end
        version
      end

      def restore(build: nil)
        backups = list_backups
        if backups.empty?
          puts "No backups found."
          return
        end

        target = if build
          backups.find { |b| b[:build] == build }
        else
          backups.last
        end

        unless target
          puts "No backup found for build #{build}. Available:"
          backups.each { |b| puts "  #{b[:short]} (build #{b[:build]})" }
          return
        end

        asar_gz = File.join(target[:path], "app.asar.gz")
        unless File.exist?(asar_gz)
          puts "Backup file missing: #{asar_gz}"
          return
        end

        data = Zlib::GzipReader.open(asar_gz) { |gz| gz.read }
        File.write(APP_ASAR, data, mode: "wb")
        system("codesign", "--force", "--deep", "--sign", "-", "/Applications/Codex.app")
        size_mb = (data.bytesize.to_f / 1024 / 1024).round(1)
        puts "✅ Restored Codex #{target[:short]} (build #{target[:build]}) — #{size_mb}MB"
        puts "   Quit and reopen Codex."
      end

      def list_backups
        return [] unless Dir.exist?(BACKUP_DIR)
        Dir.entries(BACKUP_DIR).filter_map do |entry|
          path = File.join(BACKUP_DIR, entry)
          next unless File.directory?(path) && entry.match?(/\A\d+\z/)
          version_file = File.join(path, "version.txt")
          version = File.exist?(version_file) ? File.read(version_file).strip : "unknown"
          { build: entry, short: version.split("(").first&.strip || version, path: path }
        end.sort_by { |b| b[:build].to_i }
      end


      def codex_version
        plist = "/Applications/Codex.app/Contents/Info.plist"
        short = `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "#{plist}" 2>/dev/null`.strip
        build = `/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "#{plist}" 2>/dev/null`.strip
        { short: short, build: build }
      end

      def patch_asar(skip_deep: true)
        unless File.exist?(APP_ASAR)
          puts "Codex not found at #{APP_ASAR}"
          return false
        end

        unless command?("npx")
          puts "npx is required to patch the ASAR bundle."
          return false
        end

        # Save a backup of the current ASAR into backups/<build>/ before modifying it.
        # This gives re-patch a restore point to fall back to.
        backup

        backup_path = File.join(RUNTIME_DIR, "app.asar.before-llm-proxy-patch")
        Dir.mkdir(RUNTIME_DIR) unless Dir.exist?(RUNTIME_DIR)

        unless File.exist?(backup_path)
          FileUtils.cp(APP_ASAR, backup_path)
          puts "  Also saved first-time original to " + File.basename(backup_path)
        end

        versioned = File.join(RUNTIME_DIR, "app.asar.before-patch.#{asar_hash(APP_ASAR)[..11]}")
        unless File.exist?(versioned)
          FileUtils.cp(APP_ASAR, versioned)
          puts "  Also saved hash-versioned snapshot (" + File.basename(versioned) + ")"
        end

        quit
        workdir = File.join(RUNTIME_DIR, "app-asar-work")
        FileUtils.rm_rf(workdir) if Dir.exist?(workdir)
        Dir.mkdir(workdir)

        system("npx", "--yes", "asar", "extract", APP_ASAR, workdir)
        unless $?.success?
          puts "Failed to extract app.asar"
          return false
        end

        bundle = find_model_queries_bundle(workdir)
        if bundle
          patch_model_queries(bundle) || return
        else
          puts "! Could not find model picker bundle — model list may be limited."
        end

        goal_bundle = find_goal_handler_bundle(workdir)
        if goal_bundle
          patch_goal_handlers(goal_bundle) || puts("! Goal handler patch failed — /goal may not work.")
        else
          puts "! Could not find goal handler bundle — /goal may not work."
        end

        system("npx", "--yes", "asar", "pack", "--unpack-dir", "**/*.node", workdir, APP_ASAR)
        unless $?.success?
          puts "Failed to repack app.asar"
          return false
        end

        puts "Patched Codex app.asar (#{File.size(APP_ASAR)} bytes)."

        fix_asar_integrity
        resign(skip_deep:)
        true
      end

      def restore_asar
        backup_path = File.join(RUNTIME_DIR, "app.asar.before-llm-proxy-patch")
        unless File.exist?(backup_path)
          puts "No backup found at #{backup_path}"
          return false
        end

        quit
        FileUtils.cp(backup_path, APP_ASAR)
        fix_asar_integrity
        resign(skip_deep: true)
        puts "Restored original app.asar."
        true
      end

      def quit
        script = 'tell application "Codex" to if it is running then quit'
        system("osascript", "-e", script)
        sleep 0.5
      rescue
      end

      private

      def command?(cmd)
        system("which", cmd)
      end

      def asar_hash(path)
        Digest::SHA256.hexdigest(File.read(path))
      end

      def find_model_queries_bundle(workdir)
        assets = File.join(workdir, "webview", "assets")
        return nil unless Dir.exist?(assets)

        candidates = Dir.glob(File.join(assets, "models-and-reasoning-efforts-*.js")).sort
        candidates.concat(Dir.glob(File.join(assets, "model-queries-*.js")).sort)
        candidates.concat(Dir.glob(File.join(assets, "*.js")).sort - candidates)

        needle = "s=i&&e!==`amazonBedrock`"

        candidates.find do |path|
          text = File.read(path, encoding: "UTF-8", invalid: :replace)
          text.include?(needle)
        rescue
          false
        end
      end

      def patch_model_queries(bundle)
        needle = "s=i&&e!==`amazonBedrock`"
        replacement = "s=!1"
        text = File.read(bundle)

        if text.include?(replacement) && !text.include?(needle)
          puts "  Model picker patch already applied."
          return true
        end

        unless text.include?(needle)
          puts "  Could not find model picker pattern in #{File.basename(bundle)}"
          return false
        end

        File.write(bundle, text.sub(needle, replacement))
        puts "  ✅ Model picker allowlist filter patched."
        true
      end

      def find_goal_handler_bundle(workdir)
        assets = File.join(workdir, "webview", "assets")
        return nil unless Dir.exist?(assets)

        candidates = Dir.glob(File.join(assets, "*.js")).sort

        candidates.find do |path|
          text = File.read(path, encoding: "UTF-8", invalid: :replace)
          text.include?('"set-thread-goal":_U(async(e,{appendTranscriptItem:')
        rescue
          false
        end
      end

      GOAL_PATCHES = [
        {
          name: "set-thread-goal",
          needle: '_U(async(e,{appendTranscriptItem:t,conversationId:n,objective:r})=>{let{goal:i}=await e.sendRequest(`thread/goal/set`,{threadId:n,objective:r});return t!==!1&&ht(e,n,i),i.status===`active`&&e.maybeContinueActiveThreadGoal(n),i})',
          replacement: '_U(async(e,{appendTranscriptItem:t,conversationId:n,objective:r})=>{let i;try{({goal:i}=await e.sendRequest(`thread/goal/set`,{threadId:n,objective:r}))}catch{let _e=Date.now();i={id:crypto.randomUUID(),objective:r,status:`active`,thread_id:n,created_at:Math.floor(_e/1e3),updated_at:Math.floor(_e/1e3),created_at_ms:_e,updated_at_ms:_e};fetch(`http://127.0.0.1:8765/api/goals`,{method:`POST`,headers:{"Content-Type":`application/json`},body:JSON.stringify({operation:`set`,threadId:n,objective:r,status:`active`})}).catch(()=>{})}try{return t!==!1&&ht(e,n,i),i.status===`active`&&e.maybeContinueActiveThreadGoal(n),i}catch{return i}})',
        },
        {
          name: "set-thread-goal-status",
          needle: '_U(async(e,{conversationId:t,status:n})=>{let{goal:r}=await e.sendRequest(`thread/goal/set`,{threadId:t,status:n});return e.updateConversationState(t,e=>{e.threadGoalResumeConfirmation=null}),n===`active`&&e.maybeContinueActiveThreadGoal(t),r})',
          replacement: '_U(async(e,{conversationId:t,status:n})=>{let r;try{({goal:r}=await e.sendRequest(`thread/goal/set`,{threadId:t,status:n}))}catch{r={status:n,updated_at_ms:Date.now()};fetch(`http://127.0.0.1:8765/api/goals`,{method:`POST`,headers:{"Content-Type":`application/json`},body:JSON.stringify({operation:`set_status`,threadId:t,status:n})}).catch(()=>{})}return e.updateConversationState(t,e=>{e.threadGoalResumeConfirmation=null}),n===`active`&&e.maybeContinueActiveThreadGoal(t),r})',
        },
        {
          name: "clear-thread-goal",
          needle: '_U(async(e,{conversationId:t})=>e.sendRequest(`thread/goal/clear`,{threadId:t}))',
          replacement: '_U(async(e,{conversationId:t})=>{try{return await e.sendRequest(`thread/goal/clear`,{threadId:t})}catch{fetch(`http://127.0.0.1:8765/api/goals`,{method:`POST`,headers:{"Content-Type":`application/json`},body:JSON.stringify({operation:`clear`,threadId:t})}).catch(()=>{});return null}})',
        },
      ].freeze

      def patch_goal_handlers(bundle)
        text = File.read(bundle, encoding: "UTF-8", invalid: :replace)
        patched = false

        GOAL_PATCHES.each do |p|
          if text.include?(p[:replacement])
            puts "  #{p[:name]} already patched."
            patched = true
          elsif text.include?(p[:needle])
            text = text.sub(p[:needle], p[:replacement])
            puts "  ✅ #{p[:name]} handler patched."
            patched = true
          else
            puts "  ! Could not find #{p[:name]} handler pattern."
          end
        end

        File.write(bundle, text) if patched
        patched
      end

      def fix_asar_integrity
        plist = "/Applications/Codex.app/Contents/Info.plist"
        hash = compute_asar_header_hash(APP_ASAR)
        system("/usr/libexec/PlistBuddy", "-c", "Set :ElectronAsarIntegrity:Resources/app.asar:hash #{hash}", plist)
      end

      def compute_asar_header_hash(path)
        data = File.read(path, mode: "rb")
        header_size = data[4..7].unpack1("V")
        json_size = data[12..15].unpack1("V")
        header_json = data.byteslice(16, json_size)
        Digest::SHA256.hexdigest(header_json)
      end

      def resign(skip_deep: true)
        args = ["codesign", "--force", "--sign", "-"]
        args.insert(2, "--deep") unless skip_deep
        args << "/Applications/Codex.app"
        system(*args)
      end
    end
  end
end
