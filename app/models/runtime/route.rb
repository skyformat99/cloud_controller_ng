require 'cloud_controller/dea/client'

module VCAP::CloudController
  class Route < Sequel::Model
    ROUTE_REGEX = /\A#{URI.regexp}\Z/

    class InvalidDomainRelation < CloudController::Errors::InvalidRelation; end
    class InvalidAppRelation < CloudController::Errors::InvalidRelation; end
    class InvalidOrganizationRelation < CloudController::Errors::InvalidRelation; end
    class DockerDisabled < CloudController::Errors::InvalidRelation; end

    many_to_one :domain
    many_to_one :space, after_set: :validate_changed_space

    # This is a v3 relationship
    one_to_many :route_mappings, class: 'VCAP::CloudController::RouteMappingModel', key: :route_guid, primary_key: :guid

    # This is a v2 relationship for the /v2/route_mappings endpoints and associations
    one_to_many :app_route_mappings, class: 'VCAP::CloudController::RouteMapping'

    many_to_many :apps,
                 distinct: true,
                 order: Sequel.asc(:id),
                 before_add:   :validate_app,
                 after_add:    :handle_add_app,
                 after_remove: :handle_remove_app

    one_to_one :route_binding
    one_through_one :service_instance, join_table: :route_bindings

    add_association_dependencies apps: :nullify, route_mappings: :destroy

    export_attributes :host, :path, :domain_guid, :space_guid, :service_instance_guid, :port
    import_attributes :host, :path, :domain_guid, :space_guid, :app_guids, :port

    def fqdn
      host.empty? ? domain.name : "#{host}.#{domain.name}"
    end

    def uri
      "#{fqdn}#{path}"
    end

    def as_summary_json
      {
        guid:   guid,
        host:   host,
        port:   port,
        path:   path,
        domain: {
          guid: domain.guid,
          name: domain.name
        }
      }
    end

    alias_method :old_path, :path
    def path
      old_path.nil? ? '' : old_path
    end

    def port
      super == 0 ? nil : super
    end

    def organization
      space.organization if space
    end

    def route_service_url
      route_binding && route_binding.route_service_url
    end

    def validate
      validates_presence :domain
      validates_presence :space

      errors.add(:host, :presence) if host.nil?

      validates_format /^([\w\-]+|\*)$/, :host if host && !host.empty?

      validate_uniqueness_on_host_and_domain if path.empty? && port.nil?
      validate_uniqueness_on_host_domain_and_port if path.empty?
      validate_uniqueness_on_host_domain_and_path if port.nil?

      validate_host_and_domain_in_different_space
      validate_host
      validate_fqdn
      validate_path
      validate_domain
      validate_total_routes
      validate_ports
      validate_total_reserved_route_ports if port && port > 0
      errors.add(:host, :domain_conflict) if domains_match?

      RouteValidator.new(self).validate
    rescue RoutingApi::UaaUnavailable
      errors.add(:routing_api, :uaa_unavailable)
    rescue RoutingApi::RoutingApiUnavailable
      errors.add(:routing_api, :routing_api_unavailable)
    rescue RoutingApi::RoutingApiDisabled
      errors.add(:routing_api, :routing_api_disabled)
    end

    def validate_ports
      return unless port
      errors.add(:port, :invalid_port) if port < 0 || port > 65535
    end

    def validate_path
      return if path == ''

      if !ROUTE_REGEX.match("pathcheck://#{host}#{path}")
        errors.add(:path, :invalid_path)
      end

      if path == '/'
        errors.add(:path, :single_slash)
      end

      if path[0] != '/'
        errors.add(:path, :missing_beginning_slash)
      end

      if path =~ /\?/
        errors.add(:path, :path_contains_question)
      end
    end

    def domains_match?
      return false if domain.nil? || host.nil? || host.empty?
      !Domain.find(name: fqdn).nil?
    end

    def all_apps_diego?
      apps.all?(&:diego?)
    end

    def validate_app(app)
      return unless space && app && domain

      unless app.space == space
        raise InvalidAppRelation.new(app.guid)
      end

      unless domain.usable_by_organization?(space.organization)
        raise InvalidDomainRelation.new(domain.guid)
      end
    end

    # If you change this function, also change _add_route in app.rb
    def _add_app(app, hash={})
      app_port = app.user_provided_ports.first unless app.user_provided_ports.blank?
      model.db[:apps_routes].insert(hash.merge(app_id: app.id, app_port: app_port, route_id: id, guid: SecureRandom.uuid))
    end

    def validate_changed_space(new_space)
      apps.each { |app| validate_app(app) }
      raise InvalidOrganizationRelation if domain && !domain.usable_by_organization?(new_space.organization)
    end

    def self.user_visibility_filter(user)
      {
         space_id: Space.dataset.join_table(:inner, :spaces_developers, space_id: :id, user_id: user.id).select(:spaces__id).union(
           Space.dataset.join_table(:inner, :spaces_managers, space_id: :id, user_id: user.id).select(:spaces__id)
           ).union(
             Space.dataset.join_table(:inner, :spaces_auditors, space_id: :id, user_id: user.id).select(:spaces__id)
           ).union(
             Space.dataset.join_table(:inner, :organizations_managers, organization_id: :organization_id, user_id: user.id).select(:spaces__id)
           ).union(
             Space.dataset.join_table(:inner, :organizations_auditors, organization_id: :organization_id, user_id: user.id).select(:spaces__id)
           ).select(:id)
       }
    end

    def in_suspended_org?
      space.in_suspended_org?
    end

    def tcp?
      domain.shared? && domain.tcp? && port.present? && port > 0
    end

    private

    def before_destroy
      destroy_route_bindings
      super
    end

    def destroy_route_bindings
      errors = ServiceBindingDelete.new.delete(self.route_binding_dataset)
      raise errors.first unless errors.empty?
    end

    def around_destroy
      loaded_apps = apps
      super

      loaded_apps.each do |app|
        handle_remove_app(app)

        if app.dea_update_pending?
          Dea::Client.update_uris(app)
        end
      end
    end

    def validate_host_and_domain_in_different_space
      return unless space && domain && domain.shared?

      validates_unique [:domain_id, :host], message: :host_and_domain_taken_different_space do |ds|
        ds.where(port: 0).exclude(space: space)
      end
    end

    def handle_add_app(app)
      app.handle_add_route(self)
    end

    def handle_remove_app(app)
      app.handle_remove_route(self)
    end

    def validate_host
      errors.add(:host, "must be no more than #{Domain::MAXIMUM_DOMAIN_LABEL_LENGTH} characters") if host && host.length > Domain::MAXIMUM_DOMAIN_LABEL_LENGTH
    end

    def validate_fqdn
      return unless host
      length_with_period_separator = host.length + 1
      host_label_length = host.length > 0 ? length_with_period_separator : 0
      total_domain_too_long = host_label_length + domain.name.length > Domain::MAXIMUM_FQDN_DOMAIN_LENGTH
      errors.add(:host, "must be no more than #{Domain::MAXIMUM_FQDN_DOMAIN_LENGTH} characters when combined with domain name") if total_domain_too_long
    end

    def validate_domain
      errors.add(:domain, :invalid_relation) if !valid_domain
      errors.add(:host, 'is required for shared-domains') if !valid_host_for_shared_domain
    end

    def valid_domain
      return false if domain.nil?

      domain_change = column_change(:domain_id)
      return false if !new? && domain_change && domain_change[0] != domain_change[1]

      return false if space && !domain.usable_by_organization?(space.organization) # domain is not usable by the org

      true
    end

    def domain_shared_and_empty_host_and_port?
      domain && domain.shared? && (host.blank? && values[:port].blank?)
    end

    def valid_host_for_shared_domain
      return false if domain_shared_and_empty_host_and_port?
      true
    end

    def validate_total_routes
      return unless new? && space

      space_routes_policy = MaxRoutesPolicy.new(space.space_quota_definition, SpaceRoutes.new(space))
      org_routes_policy   = MaxRoutesPolicy.new(space.organization.quota_definition, OrganizationRoutes.new(space.organization))

      if space.space_quota_definition && !space_routes_policy.allow_more_routes?(1)
        errors.add(:space, :total_routes_exceeded)
      end

      if !org_routes_policy.allow_more_routes?(1)
        errors.add(:organization, :total_routes_exceeded)
      end
    end

    def validate_total_reserved_route_ports
      return unless new? && space
      org_route_port_counter = OrganizationReservedRoutePorts.new(space.organization)
      org_quota_definition = space.organization.quota_definition
      org_reserved_route_ports_policy = MaxReservedRoutePortsPolicy.new(org_quota_definition, org_route_port_counter)

      space_quota_definition = space.space_quota_definition

      if space_quota_definition.present?
        space_route_port_counter = SpaceReservedRoutePorts.new(space.organization)
        space_reserved_route_ports_policy = MaxReservedRoutePortsPolicy.new(space_quota_definition, space_route_port_counter)

        if !space_reserved_route_ports_policy.allow_more_route_ports?
          errors.add(:space, :total_reserved_route_ports_exceeded)
        end
      end

      if !org_reserved_route_ports_policy.allow_more_route_ports?
        errors.add(:organization, :total_reserved_route_ports_exceeded)
      end
    end

    def validate_uniqueness_on_host_and_domain
      validates_unique [:host, :domain_id] do |ds|
        ds.where(path: '', port: 0)
      end
    end

    def validate_uniqueness_on_host_domain_and_port
      validates_unique [:host, :domain_id, :port] do |ds|
        ds.where(path: '')
      end
    end

    def validate_uniqueness_on_host_domain_and_path
      validates_unique [:host, :domain_id, :path] do |ds|
        ds.where(port: 0)
      end
    end
  end
end