#
# Author:: Nate Walck (<nate.walck@gmail.com>)
# Copyright:: Copyright 2015-2016, Facebook, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require_relative "../resource"
require_relative "../log"
require_relative "../resource/file"
require "uuidtools"
require "plist"

class Chef
  class Resource
    class OsxProfile < Chef::Resource
      unified_mode true

      provides :osx_profile
      provides :osx_config_profile

      description "Use the **osx_profile** resource to manage configuration profiles (.mobileconfig files) on the macOS platform. The osx_profile resource installs profiles by using the uuidgen library to generate a unique ProfileUUID, and then using the profiles command to install the profile on the system."
      introduced "12.7"

      property :profile_name, String,
        description: "Use to specify the name of the profile, if different from the name of the resource block.",
        name_property: true

      property :profile, [ String, Hash ],
        description: "Use to specify a profile. This may be the name of a profile contained in a cookbook or a Hash that contains the contents of the profile."

      property :identifier, String,
        description: "Use to specify the identifier for the profile, such as com.company.screensaver."

      # this is not a property it is necessary for the tempfile this resource uses to work (FIXME: this is terrible)
      #
      # @api private
      #
      def path(path = nil)
        @path ||= path
        @path
      end

      action_class do
        def load_current_resource
          @current_resource = Chef::Resource::OsxProfile.new(new_resource.name)
          current_resource.profile_name(new_resource.profile_name)

          if new_profile_hash
            new_profile_hash["PayloadUUID"] = config_uuid(new_profile_hash)
          end

          current_resource.profile(current_profile)
        end

        def current_profile
          all_profiles = get_installed_profiles

          if all_profiles && all_profiles.key?("_computerlevel")
            return all_profiles["_computerlevel"].find do |item|
              item["ProfileIdentifier"] == new_profile_identifier
            end
          end
          nil
        end

        def invalid_profile_name?(name_or_identifier)
          name_or_identifier.end_with?(".mobileconfig") || !/^\w+(?:(\.| )\w+)+$/.match(name_or_identifier)
        end

        def check_resource_semantics!
          if mac? && node["platform_version"] =~ "> 10.15"
            raise "The osx_profile resource is not available on macOS Bug Sur or above due to the removal of apple support for CLI installation of profiles"
          end

          if action == :remove
            if new_profile_identifier
              if invalid_profile_name?(new_profile_identifier)
                raise "when removing using the identifier property, it must match the profile identifier"
              end
            else
              if invalid_profile_name?(new_resource.profile_name)
                raise "When removing by resource name, it must match the profile identifier"
              end
            end
          end

          if action == :install
            if new_profile_hash.is_a?(Hash) && !new_profile_hash.include?("PayloadIdentifier")
              raise "The specified profile does not seem to be valid"
            end
            if new_profile_hash.is_a?(String) && !new_profile_hash.end_with?(".mobileconfig")
              raise "#{new_profile_hash}' is not a valid profile"
            end
          end
        end
      end

      action :install do
        unless profile_installed?
          converge_by("install profile #{new_profile_identifier}") do
            profile_path = write_profile_to_disk
            install_profile(profile_path)
            get_installed_profiles(true)
          end
        end
      end

      action :remove do
        # Clean up profile after removing it
        if profile_installed?
          converge_by("remove profile #{new_profile_identifier}") do
            remove_profile
            get_installed_profiles(true)
          end
        end
      end

      action_class do
        private

        def profile
          @profile ||= new_resource.profile || new_resource.profile_name
        end

        def new_profile_hash
          @new_profile_hash ||= get_profile_hash(profile)
        end

        def new_profile_identifier
          @new_profile_identifier ||= if new_profile_hash
                                        new_profile_hash["PayloadIdentifier"]
                                      else
                                        new_resource.identifier || new_resource.profile_name
                                      end
        end

        def load_profile_hash(new_profile)
          # file must exist in cookbook
          return nil unless new_profile.end_with?(".mobileconfig")

          unless cookbook_file_available?(new_profile)
            raise Chef::Exceptions::FileNotFound, "#{self}: '#{new_profile}' not found in cookbook"
          end

          cookbook_profile = cache_cookbook_profile(new_profile)
          ::Plist.parse_xml(cookbook_profile)
        end

        def cookbook_file_available?(cookbook_file)
          run_context.has_cookbook_file_in_cookbook?(
            new_resource.cookbook_name, cookbook_file
          )
        end

        def get_cache_dir
          Chef::FileCache.create_cache_path(
            "profiles/#{new_resource.cookbook_name}"
          )
        end

        def cache_cookbook_profile(cookbook_file)
          Chef::FileCache.create_cache_path(
            ::File.join(
              "profiles",
              new_resource.cookbook_name,
              ::File.dirname(cookbook_file)
            )
          )

          path = ::File.join( get_cache_dir, "#{cookbook_file}.remote")

          cookbook_file path do
            cookbook_name = new_resource.cookbook_name
            source(cookbook_file)
            backup(false)
            run_action(:create)
          end

          path
        end

        def get_profile_hash(new_profile)
          if new_profile.is_a?(Hash)
            new_profile
          elsif new_profile.is_a?(String)
            load_profile_hash(new_profile)
          end
        end

        def config_uuid(profile)
          # Make a UUID of the profile contents and return as string
          UUIDTools::UUID.sha1_create(
            UUIDTools::UUID_DNS_NAMESPACE,
            profile.to_s
          ).to_s
        end

        def write_profile_to_disk
          # FIXME: this is kind of terrible, the resource needs a tempfile to use and
          # wants it created similarly to the file providers (with all the magic necessary
          # for determining if it should go in the cwd or into a tmpdir), but it abuses
          # the Chef::FileContentManagement::Tempfile API to do that, which requires setting
          # a `path` method on the resource because of tight-coupling to the file provider
          # pattern.  We don't just want to use a file here because the point is to get
          # at the tempfile pattern from the file provider, but to feed that into a shell
          # command rather than deploying the file to somewhere on disk.  There's some
          # better API that needs extracting here.
          new_resource.path(Chef::FileCache.create_cache_path("profiles"))
          tempfile = Chef::FileContentManagement::Tempfile.new(new_resource).tempfile
          tempfile.write(new_profile_hash.to_plist)
          tempfile.close
          tempfile.path
        end

        def install_profile(profile_path)
          cmd = [ "/usr/bin/profiles", "-I", "-F", profile_path ]
          logger.trace("cmd: #{cmd.join(" ")}")
          shell_out!(*cmd)
        end

        def remove_profile
          cmd = [ "/usr/bin/profiles", "-R", "-p", new_profile_identifier ]
          logger.trace("cmd: #{cmd.join(" ")}")
          shell_out!(*cmd)
        end

        #
        # FIXME FIXME FIXME
        # The node object should not be used for caching state like this and this is not a public API and may break.
        # FIXME FIXME FIXME
        #

        def get_installed_profiles(update = nil)
          if update
            node.run_state[:config_profiles] = query_installed_profiles
          else
            node.run_state[:config_profiles] ||= query_installed_profiles
          end
          logger.trace("Saved profiles to run_state")
        end

        def query_installed_profiles
          Tempfile.open("allprofiles.plist") do |tempfile|
            shell_out!( "/usr/bin/profiles", "-P", "-o", tempfile.path )
            ::Plist.parse_xml(tempfile)
          end
        end

        def profile_installed?
          # Profile Identifier and UUID must match a currently installed profile
          return false if current_resource.profile.nil? || current_resource.profile.empty?
          return true if action == :remove

          current_resource.profile["ProfileUUID"] == new_profile_hash["PayloadUUID"]
        end
      end
    end
  end
end
