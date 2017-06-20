require 'find'
require 'open3'
require 'shellwords'

class SafeZipper
  def self.unzip(zip_path, zip_destination)
    new(zip_path, zip_destination).unzip!
  end

  def self.zip(root_path, zip_output)
    new(root_path, zip_output).zip!
  end

  def initialize(zip_path, zip_destination)
    @zip_path = File.expand_path(zip_path)
    @zip_destination = File.expand_path(zip_destination)
  end

  def unzip!
    raise CloudController::Errors::ApiError.new_from_details('AppBitsUploadInvalid', 'Destination does not exist') unless File.directory?(@zip_destination)
    raise CloudController::Errors::ApiError.new_from_details('AppBitsUploadInvalid', 'Relative path(s) outside of root folder') if any_outside_relative_paths?

    unzip

    raise CloudController::Errors::ApiError.new_from_details('AppBitsUploadInvalid', 'Symlink(s) point outside of root folder') if any_outside_symlinks?

    size
  end

  def zip!
    raise CloudController::Errors::ApiError.new_from_details('AppPackageInvalid', 'Path does not exist') unless File.exist?(@zip_path)
    raise CloudController::Errors::ApiError.new_from_details('AppPackageInvalid', 'Path does not exist') unless File.exist?(File.dirname(@zip_destination))

    zip
  end

  private

  def unzip
    # @unzip ||= `unzip -qq -: -d #{Shellwords.escape(@zip_destination)} #{Shellwords.escape(@zip_path)}`
    jobs_dir = File.dirname(File.dirname(VCAP::CloudController::Config.config['runtimes_files']))
    raise CloudController::Errors::ApiError.new_from_details('AppBitsUploadInvalid', 'no config for runtimes_files') unless jobs_dir
    safe_unzip_wrapper = File.join(jobs_dir, 'bin', 'safe_unzipper')
    raise CloudController::Errors::ApiError.new_from_details('AppPackageInvalid', 'safe unzipper does not exist') unless File.exist?(safe_unzip_wrapper)

    if !@unzip
      output, error, status = Open3.capture3(%(safe_unzip_wrapper -d #{Shellwords.escape(@zip_destination)} -f #{Shellwords.escape(@zip_path)}))
      unless status.success?
        raise CloudController::Errors::ApiError.new_from_details('AppBitsUploadInvalid',
          "Unzipping had errors\n STDOUT: \"#{output}\"\n STDERR: \"#{error}\"")
      end
      @unzip = output
    end
    @unzip
  end

  def zip
    @zip ||= begin
      output, error, status = Open3.capture3(
        %(zip -q -r -D --symlinks #{Shellwords.escape(@zip_destination)} .),
        chdir: @zip_path
      )

      unless status.success?
        raise CloudController::Errors::ApiError.new_from_details('AppPackageInvalid',
          "Could not zip the package\n STDOUT: \"#{output}\"\n STDERR: \"#{error}\"")
      end

      output
    end
  end

  def zip_info
    @zip_info ||= begin
      output, error, status = Open3.capture3(%(unzip -l #{Shellwords.escape(@zip_path)}))

      unless status.success?
        raise CloudController::Errors::ApiError.new_from_details('AppBitsUploadInvalid',
          "Unzipping had errors\n STDOUT: \"#{output}\"\n STDERR: \"#{error}\"")
      end

      output
    end
  end

  def size
    @size ||= zip_info.split("\n").last.match(/\A\s*(\d+)/)[1].to_i
  end

  def any_outside_relative_paths?
    zip_info.split("\n")[3..-3].map do |info|
      info.match(/\A\s*\d+\s+[\d-]+\s+[\d:]+\s+(.*)\z/)[1]
    end.any? do |path|
      !VCAP::CloudController::FilePathChecker.safe_path? path, @zip_destination
    end
  end

  def any_outside_symlinks?
    Find.find(@zip_destination).find do |item|
      File.symlink?(item) && !VCAP::CloudController::FilePathChecker.safe_path?(File.readlink(item), @zip_destination)
    end
  end
end
