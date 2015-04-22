class Admin::ListingShapesController < ApplicationController
  before_filter :ensure_is_admin

  ensure_feature_enabled :shape_ui

  LISTING_SHAPES_NAVI_LINK = "listing_shapes"

  ListingShapeForm = FormUtils.define_form(
    "ListingShapeForm",
    :name,
    :action_button_label,
    :shipping_enabled,
    :price_enabled,
    :online_payments,
    :units,
  ).with_validations {
    validates :name, presence: true
    validates :action_button_label, presence: true
    validates :shipping_enabled, inclusion: { in: [true, false] }
    # TODO Add validations
  }

  def index
    templates = ListingShapeTemplates.new(get_processes(@current_community.id))
    shapes = all_shapes(@current_community.id)

    render("index",
           locals: {
             selected_left_navi_link: LISTING_SHAPES_NAVI_LINK,
             templates: templates.all,
             listing_shapes: all_shapes(@current_community.id)})
  end

  def new
    processes = get_processes(@current_community.id)
    templates = ListingShapeTemplates.new(processes)

    unless templates.available?(params[:template])
      flash[:error] = "Invalid template: #{params[:template]}"
      return redirect_to action: :index
    end

    template = templates.find(params[:template])
    render("new", locals: view_locals(template, processes, available_locales()))
  end

  def edit
    processes = get_processes(@current_community.id)

    shape = get_shape(@current_community.id, params[:id])
    return redirect_to error_not_found_path if shape.nil?

    render("edit", locals: view_locals(shape, processes, available_locales()))
  end

  def create
    processes = get_processes(@current_community.id)

    shape_form = parse_params_to_form(params)

    process_find_opts = {
      process: shape_form.online_payments ? :preauthorize : :none,
      author_is_seller: true # FIXME
    }

    process = processes.find { |p| p.slice(*process_find_opts.keys) == process_find_opts }.tap { |p|
      raise ArgumentError.new("Can not find suitable transaction process for #{process_find_opts}") if p.nil?
    }

    unless shape_form.valid?
      flash[:error] = shape_form.errors.full_messages.join(", ")
      return render_edit(shape, @current_community.id, available_locales())
    end

    create_result =
      create_translations(@current_community.id, shape_form)
      .and_then { |translations|
      name_tr_key, action_button_tr_key = translations.map { |t| t[:translation_key] }
      name_translation = translations.first[:translations]
      basename = name_translation.find { |t| t[:locale] == @current_community.default_locale } || name_translations.first
      create_shape(@current_community.id, name_tr_key, action_button_tr_key, basename[:translation], process[:id], shape_form)
    }

    if create_result.success
      flash[:message] = t("admin.listing_shapes.new.create_success")
      redirect_to action: :index
    else
      flash[:error] = t("admin.listing_shapes.new.create_failure")
      # TODO RENDER SOMETHING
    end

  end

  def update
    processes = get_processes(@current_community.id)

    shape = get_shape(@current_community.id, params[:id])
    return redirect_to error_not_found_path if shape.nil?

    shape_form = parse_params_to_form(params)
    unless shape_form.valid?
      flash[:error] = shape_form.errors.full_messages.join(", ")
      return render_edit(shape, @current_community.id, available_locales())
    end

    update_result =
      update_translations(@current_community.id, shape, shape_form)
      .and_then { update_shape(shape, shape_form) }

    if update_result[:success]
      flash[:notice] = t("admin.listing_shapes.edit.update_success", shape: translate(shape[:name_tr_key]))
      return redirect_to admin_listing_shapes_path
    else
      flash[:error] = t("admin.listing_shapes.edit.update_failure")
      render("edit", locals: edit_view_locals(shape, processes, available_locales()))
    end
  end


  private

  def editable_fields(processes)
    # TODO Read the processes and define which options are editable
    {
      shipping_enabled: true,
      price_enabled: true,
      online_payments: true
    }
  end

  def view_locals(shape, processes, available_locs)
    { selected_left_navi_link: LISTING_SHAPES_NAVI_LINK,
      editable_fields: editable_fields(processes),
      shape: shape,
      shape_form: to_form_data(shape, available_locs),
      locale_name_mapping: available_locs.map { |name, l| [l, name]}.to_h }
  end


  def parse_params_to_form(params)
    ListingShapeForm.new(
      params
      .slice(:name, :action_button_label)
      .merge(shipping_enabled: params[:shipping_enabled] == "true")
      .merge(price_enabled: params[:price_enabled] == "true")
      .merge(online_payments: params[:online_payments] == "true")
      .merge(units: Maybe(params[:units]).or_else([]).map { |t, _| parse_unit(t) }))
  end

  def parse_unit(type)
    type_sym = type.to_sym
    selector =
      if type_sym == :day
        :day
      else
        :number
      end
    {type: type_sym, quantity_selector: selector}
  end

  def to_form_data(shape, available_locs)
    shape_units = shape[:units].map { |t| t[:type] }.to_set
    units = ListingShapeHelper.predefined_unit_types
      .map { |t| {type: t, enabled: shape_units.include?(t), label: t("admin.listing_shapes.units.#{t}")} }
      .concat(shape[:units]
              .select { |unit| unit[:type] == :custom }
              .map { |unit| {type: unit[:type], enabled: true, label: translate(unit[:translation_key])} })

    ListingShapeForm.new(name: make_translations(shape[:name_tr_key], available_locs),
                         price_enabled: shape[:price_enabled],
                         online_payments: shape[:online_payments],
                         action_button_label: make_translations(shape[:action_button_tr_key], available_locs),
                         shipping_enabled: shape[:shipping_enabled],
                         units: units)
  end

  def make_translations(tr_key, locales)
    locales.map { |(loc_name, loc_key)|
      [loc_key, t(tr_key, locale: loc_key)]
    }.to_h

  end

  def update_translations(community_id, shape, shape_form)
    tr_groups = TranslationServiceHelper.to_per_key_translations({
      shape[:name_tr_key] => shape_form.name,
      shape[:action_button_tr_key] => shape_form.action_button_label})

    translations_api.translations.create(community_id, tr_groups)
  end

  def create_translations(community_id, shape_form)
    tr_groups = [
      {translations: shape_form.name.map { |loc, t| {locale: loc, translation: t} }},
      {translations: shape_form.action_button_label.map { |loc, t| {locale: loc, translation: t} }}
    ]

    translations_api.translations.create(community_id, tr_groups)
  end

  def translations_api
    TranslationService::API::Api
  end

  def all_shapes(community_id)
    listing_api.shapes.get(community_id: community_id)
      .maybe()
      .or_else([])
  end

  def get_shape(community_id, listing_shape_id)
    listing_api.shapes.get(community_id: community_id, listing_shape_id: listing_shape_id)
      .maybe()
      .or_else(nil)
  end

  def get_processes(community_id)
    TransactionService::API::Api.processes.get(community_id: community_id)[:data]
  end

  def create_shape(community_id, name_tr_key, action_button_tr_key, basename, transaction_process_id, shape_form)
    listing_api.shapes.create(
      community_id: community_id,
      opts: {
        transaction_process_id: transaction_process_id,
        name_tr_key: name_tr_key,
        action_button_tr_key: action_button_tr_key,
        shipping_enabled: shape_form.shipping_enabled,
        price_enabled: shape_form.price_enabled,
        units: shape_form.units,
        basename: basename
      }
    )
  end

  def update_shape(shape, shape_form)
    listing_api.shapes.update(
      community_id: shape[:community_id],
      listing_shape_id: shape[:id],
      opts: {
        shipping_enabled: shape_form.shipping_enabled,
        price_enabled: shape_form.price_enabled,
        units: shape_form.units
      }
    )
  end

  def listing_api
    ListingService::API::Api
  end
end
