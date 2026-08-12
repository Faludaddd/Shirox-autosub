require 'xcodeproj'

project_path = 'Shirox.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# All three targets so the files compile on every platform.
targets = project.targets.select { |t| ['Shirox_iOS', 'Shirox_macOS', 'Shirox_tvOS'].include?(t.name) }
puts "Targets: #{targets.map(&:name).join(', ')}"

# Files recreated after being lost: [relative path from project root, group path]
lost_files = [
  ['Shirox/Services/EpisodeNotificationManager.swift',          'Shirox/Services'],
  ['Shirox/Services/WesternScheduleService.swift',              'Shirox/Services'],
  ['Shirox/Models/UnifiedScheduleEntry.swift',                  'Shirox/Models'],
  ['Shirox/Views/Shared/TransparentNavBarModifier.swift',       'Shirox/Views/Shared'],
  ['Shirox/Views/Shared/AnimatedBackgroundView.swift',          'Shirox/Views/Shared']
]

def find_or_create_group(project, group_path)
  parts = group_path.split('/')
  current = project.main_group
  parts.each do |part|
    found = current.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.name == part }
    if found
      current = found
    else
      current = current.new_group(part, part)
    end
  end
  current
end

lost_files.each do |file_path, group_path|
  full_path = File.join(File.dirname(project_path), file_path)
  unless File.exist?(full_path)
    warn "  ! Missing on disk, skipping: #{file_path}"
    next
  end

  group = find_or_create_group(project, group_path)

  # Skip if the file reference already exists in this group.
  already_in_group = group.children.any? do |c|
    c.is_a?(Xcodeproj::Project::Object::PBXFileReference) && c.path == File.basename(file_path)
  end
  if already_in_group
    puts "  = Already in group: #{file_path}"
  else
    file_ref = group.new_reference(File.basename(file_path))
    file_ref.last_known_file_type = 'sourcecode.swift'
    puts "  + Added reference: #{file_path}"
  end
end

# Ensure every target's source build phase references each file (by basename within its group).
targets.each do |target|
  phase = target.source_build_phase
  lost_files.each do |file_path, _|
    basename = File.basename(file_path)
    already_built = phase.files_references.any? { |r| r.path == basename }
    next if already_built

    # Locate the file reference anywhere in the project.
    ref = project.files.find { |f| f.path == basename && f.real_path.to_s.end_with?(file_path.split('/')[-2..-1].join('/')) }
    ref ||= project.files.find { |f| f.path == basename }
    if ref
      phase.add_file_reference(ref)
      puts "  + #{target.name}: added #{basename} to sources"
    else
      warn "  ! #{target.name}: could not find reference for #{basename}"
    end
  end
end

project.save
puts "Project saved."
