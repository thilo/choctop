$:.unshift(File.dirname(__FILE__)) unless
  $:.include?(File.dirname(__FILE__)) || $:.include?(File.expand_path(File.dirname(__FILE__)))

require "fileutils"
require "yaml"
require "builder"
require "erb"
require "uri"
require "osx/cocoa"
require "active_support"
require "RedCloth"

class ChocTop
  VERSION = '0.11.0'
  
  # Path to the Info.plist
  # Default: "Info.plist"
  attr_accessor :info_plist_path
  
  # The name of the Cocoa application
  # Default: info_plist['CFBundleExecutable'] or project folder name if "${EXECUTABLE_NAME}"
  attr_accessor :name
  
  # The version of the Cocoa application
  # Default: info_plist['CFBundleVersion']
  attr_accessor :version
  
  # The target name of the distributed DMG file
  # Default: #{name}.app
  attr_accessor :target
  def target
    @target ||= File.basename(target_bundle) if target_bundle
  end

  def target_bundle
    @target_bundle ||= Dir["build/#{build_type}/#{name}.*"].first
  end

  # The build type of the distributed DMG file
  # Default: Release
  attr_accessor :build_type

  # The Sparkle feed URL
  # Default: info_plist['SUFeedURL']
  attr_accessor :su_feed_url
  
  # The host name, e.g. some-domain.com
  # Default: host from base_url
  attr_accessor :host 
  
  # The user to log in on the remote server.
  # Default: empty
  attr_accessor :user
  
  # The url from where the xml + dmg files will be downloaded
  # Default: dir path from appcast_filename
  attr_accessor :base_url
  
  # The file name for generated release notes for the latest release
  # Default: release_notes.html
  attr_accessor :release_notes
  
  # The file name for the project readme file
  # Default: README.txt
  attr_accessor :readme
  
  # List of files/bundles to be packaged into the DMG
  attr_accessor :files

  # The path for an HTML template into which the release_notes.txt are inserted
  # after conversion to HTML
  #
  # The template file is an ERb template, with <%= yield %> as the placeholder
  # for the generated release notes.
  #
  # Currently, any CSS or JavaScript must be inline
  #
  # Default: release_notes_template.html.erb, which was generated by install_choctop into each project
  attr_accessor :release_notes_template

  # The name of the local xml file containing the Sparkle item details
  # Default: info_plist['SUFeedURL'] or linker_appcast.xml
  attr_accessor :appcast_filename
  
  # The remote directory where the xml + dmg files will be rsync'd
  attr_accessor :remote_dir
  
  # The argument flags passed to rsync
  # Default: -aCv
  attr_accessor :rsync_args
  
  # Folder from where all files will be copied into the DMG
  # Files are copied here if specified with +add_file+ before DMG creation
  attr_accessor :src_folder
  def src_folder
    @src_folder ||= "build/#{build_type}/dmg"
  end
  
  # Generated filename for a distribution, from name, version and .dmg
  # e.g. MyApp-1.0.0.dmg
  def pkg_name
    version ? "#{name}-#{version}.dmg" : versionless_pkg_name
  end
  
  # Version-less generated filename for a distribution, from name and .dmg
  # e.g. MyApp.dmg
  def versionless_pkg_name
    "#{name}.dmg"
  end
  
  # Path to generated package DMG
  def pkg
    "#{build_path}/#{pkg_name}"
  end
  
  # Path to built DMG, sparkle's xml file and other assets to be uploaded to remote server
  def build_path
    "appcast/build"
  end
  
  def mountpoint
    # @mountpoint ||= "/tmp/build/mountpoint#{rand(10000000)}"
    @mountpoint ||= "/Volumes"
  end
  
  # Path to Volume when DMG is mounted
  def volume_path
    "#{mountpoint}/#{name}"
  end
  
  #
  # Custom DMG properties
  #
  
  # Path to background .icns image file for custom DMG
  # Value should be file path relative to root of project
  # Default: a choctop supplied background image
  # that matches to default app_icon_position + applications_icon_position
  # To have no custom background, set value to +nil+
  attr_accessor :background_file
  
  # x, y position of this project's icon on the custom DMG
  # Default: a useful position for the icon against the default background
  attr_accessor :app_icon_position
  
  # x, y position of the Applications symlink icon on the custom DMG
  # Default: a useful position for the icon against the default background
  attr_accessor :applications_icon_position
  
  # Path to an .icns file for the DMG's volume icon (looks like a disk or drive)
  # Default: a DMG icon provided within choctop
  # To get default, boring blank DMG volume icon, set value to +nil+
  attr_accessor :volume_icon
  
  # Custom icon for the Applications symlink icon
  # Default: none
  attr_accessor :applications_icon
  
  # Size of icons, in pixels, within custom DMG (between 16 and 128)
  # Default: 104 - this is nice and big
  attr_accessor :icon_size
  
  # Icon text size
  # Can pass integer (12) or string ("12" or "12 px")
  # Default: 12 (px)
  attr_reader :icon_text_size
  
  def icon_text_size=(size)
    @icon_text_size = size.to_i
  end
  
  # The url for the remote package, without the protocol + host
  # e.g. if absolute url is http://mydomain.com/downloads/MyApp-1.0.dmg
  # then pkg_relative_url is /downloads/MyApp-1.0.dmg
  def pkg_relative_url
    _base_url = base_url.gsub(%r{/$}, '')
    "#{_base_url}/#{pkg_name}".gsub(%r{^.*#{host}}, '')
  end
  
  def info_plist
    @info_plist ||= OSX::NSDictionary.dictionaryWithContentsOfFile(File.expand_path(info_plist_path)) || {}
  end
  
  # Add an explicit file/bundle/folder into the DMG
  # Examples:
  #   file 'build/Release/SampleApp.app', :position => [50, 100]
  #   file :target_bundle, :position => [50, 100]
  #   file proc { 'README.txt' }, :position => [50, 100]
  #   file :position => [50, 100] { 'README.txt' }
  # Required option:
  #  +:position+ - two item array [x, y] window position
  def file(*args, &block)
    path_or_helper, options = args.first.is_a?(Hash) ? [block, args.first] : [args.first, args.last]
    throw "add_files #{path_or_helper}, :position => [x,y] option is missing" unless options[:position]
    self.files ||= {}
    files[path_or_helper] = options
  end
  alias_method :add_file, :file

  def initialize
    $choctop = $sparkle = self # define a global variable for this object ($sparkle is legacy)
    
    yield self if block_given?
    
    # Defaults
    @info_plist_path ||= 'Info.plist'
    @name ||= info_plist['CFBundleExecutable'] || File.basename(File.expand_path("."))
    @name = File.basename(File.expand_path(".")) if @name == '${EXECUTABLE_NAME}'
    @version ||= info_plist['CFBundleVersion']
    @build_type = ENV['BUILD_TYPE'] || 'Release'
    
    if @su_feed_url = info_plist['SUFeedURL']
      @appcast_filename ||= File.basename(su_feed_url)
      @base_url ||= File.dirname(su_feed_url)
    end
    if @base_url
      @host ||= URI.parse(base_url).host
    end
    @release_notes ||= 'release_notes.html'
    @readme        ||= 'README.txt'
    @release_notes_template ||= "release_notes_template.html.erb"
    @rsync_args ||= '-aCv --progress'
    
    @background_file ||= File.dirname(__FILE__) + "/../assets/sky_background.jpg"
    @app_icon_position ||= [175, 65]
    @applications_icon_position ||= [347, 270]
    @volume_icon ||= File.dirname(__FILE__) + "/../assets/DefaultVolumeIcon.icns"
    @icon_size ||= 104
    @icon_text_size ||= 12

    add_file :target_bundle, :position => app_icon_position
    
    define_tasks
  end
  
  def define_tasks
    return unless Object.const_defined?("Rake")
    
    desc "Build Xcode #{build_type}"
    task :build => "build/#{build_type}/#{target}/Contents/Info.plist"
    
    task "build/#{build_type}/#{target}/Contents/Info.plist" do
      make_build
    end
    
    desc "Create the dmg file for appcasting"
    task :dmg => :build do
      detach_dmg
      make_dmg
      detach_dmg
      convert_dmg_readonly
      add_eula
    end
    
    desc "Create/update the appcast file"
    task :feed do
      make_appcast
      make_dmg_symlink
      make_index_redirect
      make_release_notes
    end
    
    desc "Upload the appcast file to the host"
    task :upload => :feed do
      upload_appcast
    end

    task :detach_dmg do
      detach_dmg
    end
    
    task :size do
      puts configure_dmg_window
    end
  end
end
require "choctop/appcast"
require "choctop/dmg"

