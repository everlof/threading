#!/usr/bin/env ruby
# Adds the two signed extension-helper targets to Skalman.xcodeproj.
#
# Written as a script rather than as hand edits so the object graph is produced by a library
# that knows the format. Idempotent: re-running removes what it previously added first.
require 'xcodeproj'

PROJECT = 'Skalman.xcodeproj'
HELPERS = [
  {
    name: 'SkalmanExtensionHelper',
    product: 'skalman-extension-helper',
    plist: 'Helper/Info.plist',
    entitlements: 'Helper/skalman-extension-helper.entitlements',
    bundle_id: 'se.mjukis.Skalman.extension-helper'
  },
  {
    name: 'SkalmanExtensionHelperNetwork',
    product: 'skalman-extension-helper-network',
    plist: 'Helper/Info-network.plist',
    entitlements: 'Helper/skalman-extension-helper-network.entitlements',
    bundle_id: 'se.mjukis.Skalman.extension-helper-network'
  }
]
SHARED_SOURCE = 'Helper/ExtensionRunnerRequest.swift'
HELPER_MAIN = 'Helper/main.swift'
EMBED_PHASE_NAME = 'Embed Extension Helpers'

project = Xcodeproj::Project.open(PROJECT)
app = project.targets.find { |t| t.name == 'Skalman' } or abort 'no Skalman target'

# --- Idempotence: undo any previous run -------------------------------------------------
HELPERS.each do |helper|
  existing = project.targets.find { |t| t.name == helper[:name] }
  next unless existing
  app.dependencies.select { |d| d.target == existing }.each(&:remove_from_project)
  existing.remove_from_project
end
app.build_phases.select { |ph|
  ph.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) && ph.name == EMBED_PHASE_NAME
}.each { |ph| app.build_phases.delete(ph); ph.remove_from_project }
if (group = project.main_group['Helper'])
  group.recursive_children.each(&:remove_from_project)
  group.remove_from_project
end

# --- The Helper group -------------------------------------------------------------------
group = project.main_group.new_group('Helper', 'Helper')
shared_ref = group.new_reference(File.basename(SHARED_SOURCE))
main_ref = group.new_reference(File.basename(HELPER_MAIN))
HELPERS.each do |helper|
  group.new_reference(File.basename(helper[:plist]))
  group.new_reference(File.basename(helper[:entitlements]))
end

# The validator compiles into the app too, so the test bundle can exercise it. It lives here
# rather than under Sources/ because Sources/ is a synchronized folder owned by the app target,
# and a helper target cannot take a file out of it.
app.source_build_phase.add_file_reference(shared_ref, true)

# --- The helper targets -----------------------------------------------------------------
HELPERS.each do |helper|
  target = project.new_target(:command_line_tool, helper[:name], :osx, '13.0')
  target.build_phases.delete(target.frameworks_build_phase)
  target.source_build_phase.clear
  target.source_build_phase.add_file_reference(main_ref, true)
  target.source_build_phase.add_file_reference(shared_ref, true)

  target.build_configurations.each do |config|
    settings = config.build_settings
    settings['PRODUCT_NAME'] = helper[:product]
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = helper[:bundle_id]
    settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    settings['SWIFT_VERSION'] = '5.0'
    settings['CODE_SIGN_ENTITLEMENTS'] = helper[:entitlements]
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    # Required. App Sandbox cannot resolve a container without a CFBundleIdentifier, and a bare
    # Mach-O has no Info.plist unless one is linked into __TEXT.
    settings['OTHER_LDFLAGS'] = [
      '-sectcreate', '__TEXT', '__info_plist', "$(SRCROOT)/#{helper[:plist]}"
    ]
    settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
    settings['SKIP_INSTALL'] = 'YES'
    # Xcode otherwise injects debug entitlements into the signature, including a read-only
    # exception for "/" — which silently grants the helper, and every extension it execs, read
    # access to the entire filesystem in Debug builds. Containment that only holds in Release
    # is containment nobody can test.
    settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] = 'NO'
  end
end

# --- Embed into Contents/Helpers ---------------------------------------------------------
embed = app.new_copy_files_build_phase(EMBED_PHASE_NAME)
embed.symbol_dst_subfolder_spec = :wrapper
embed.dst_path = 'Contents/Helpers'
HELPERS.each do |helper|
  target = project.targets.find { |t| t.name == helper[:name] }
  app.add_dependency(target)
  build_file = embed.add_file_reference(target.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }
end

project.save
puts "targets: #{project.targets.map(&:name).join(', ')}"
puts "app phases: #{app.build_phases.map { |ph| ph.display_name }.join(' | ')}"
