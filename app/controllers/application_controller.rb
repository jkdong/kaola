class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception
  #skip_before_action :verify_authenticity_token, if: :json_request?
  skip_before_filter :verify_authenticity_token, :if => Proc.new { |c| c.request.format == 'application/json' }

  after_filter :cors_set_access_control_headers
  
  before_filter :crud_json_check
  
  def crud_json_check
     if Rails.env == "production"
       redirect_to "/500.html" unless request.format == 'application/json'
     end
  end

  def cors_set_access_control_headers
    headers['Access-Control-Allow-Origin'] = '*'
    headers['Access-Control-Allow-Methods'] = 'POST, GET, PUT, DELETE, OPTIONS'
    headers['Access-Control-Allow-Headers'] = 'Origin, Content-Type, Accept, Authorization, Token'
    headers['Access-Control-Max-Age'] = "1728000"
    headers['Access-Control-Allow-Credentials'] = true
    headers['X-Frame-Options'] = "ALLOWALL"
  end


  def set_process_name_from_request
    $0 = request.path[0,16]
  end

  def unset_process_name_from_request
    $0 = request.path[0,15] + "*"
  end

  def error_log(msg)
    File.open("log/scm-error.log","a") {|f| f.puts msg.to_s}
  end

  around_filter :exception_catch
  def exception_catch
    begin
      headers['Access-Control-Allow-Origin'] = '*'
      headers['Access-Control-Allow-Credentials'] = true
      headers['Access-Control-Allow-Methods'] = 'POST, PUT, OPTIONS, GET'
      headers['X-Frame-Options'] = "ALLOWALL"
      yield
    rescue  Exception => err
      error_log "\nInternal Server Error: #{err.class.name}, #{Time.now}"
      error_log "#{request.path}  #{request.params}"
      err_str = err.to_s
      error_log err_str
      err.backtrace.each {|x| error_log x}
      if Rails.env == "production"
        if err.class == ActiveRecord::RecordInvalid
          render_error("#{request.path}出错了: #{err_str}")
        else
          render_error("#{request.path}出错了: #{err.class}")
        end
      else
        render_error("#{request.path}出错了: #{err_str}")
      end
    end
  end

  def render_error(error, error_msg=nil, hash2=nil)
    hash = {:error => error}
    hash.merge!({:error_msg => error_msg}) if error_msg
    hash.merge!(hash2) if hash2
    render :status => 400, :json => hash.to_json
  end
  
  before_action :set_search_params, only: [:index]
  
  def set_search_params
    default_page_count = 100
    default_page_count = 10 if params[:many]
    @page_count = params[:per] || default_page_count
    @page = params[:page].to_i
    @order = params[:order]
    if @page<0
      @page = -@page
      @order = "created_at asc" if @order.nil?
      @order = @order.split(",").map do |x|
        if x.match(" desc")
          x.sub!(" desc"," asc")
        elsif x.match(" asc")
          x.sub!(" asc"," desc")
        end
        x
      end.join(",")
    end
  end
  
  def check_rawsql_json
    raise "raw_sql needs json output" unless request.format == 'application/json'
  end
  
  
  def do_search
    @list = @model_clazz.order(@order)
    @list = @list.use_index(params[:index]) if params[:index]
    if params[:s]
      check_search_param_exsit(params[:s].to_hash, @model_clazz)
      like_search
      date_search
      range_search
      in_search
      cmp_search
      exists_search
      equal_search
    end
    if params[:count]
      @count = @list.count
      if params[:count]=="2"
        render :json => {count: @count}.to_json
      end
    end
    @list = @list.page(@page).per(@page_count)
	  if params[:many] && params[:many].size>1
      @many = {}
	    params[:many].split(",").each do |x|
        @many[x] = @model_clazz.many_caches(x, @list)
      end
    end
    @belong_names = @model_clazz.belong_names
    @belongs = @model_clazz.belongs_to_multi_get(@list)
    @list
  end
  

  def equal_search
    return unless params[:s]
    query = {}
    query.merge!(simple_query(params[:s]))
    @list = @list.where(query) 
    with_dot_query(params[:s]).each do |k,v|
      model, field = k.split(".")
      hash = {(model.pluralize) => { field => v}}
      @list = @list.joins(model.to_sym).where(hash)
    end
    with_comma_query(params[:s]).each do |k,v|
      keys = k.split(",")
      t = @model_clazz.arel_table
      arel = t[keys[0].to_sym].eq(v)
      keys[1..-1].each{|key| arel = arel.or(t[key.to_sym].eq(v))}
      @list = @list.where(arel)
    end
  end

  def like_search
    return unless params[:s][:like]
    simple_query(params[:s][:like]).each {|k,v| @list = @list.where("#{k} like ?", like_value(v))}
    with_dot_query(params[:s][:like]).each do |k,v|
      model, field = k.split(".")
      @list = @list.joins(model.to_sym)
      @list = @list.where("#{model.pluralize}.#{field} like ?", like_value(v))
    end
    with_comma_query(params[:s][:like]).each do |k,v|
      keys = k.split(",")
      vv = like_value(v)
      t = @model_clazz.arel_table
      arel = t[keys[0].to_sym].matches(vv)
      keys[1..-1].each{|key| arel = arel.or(t[key.to_sym].matches(vv))}
      @list = @list.where(arel)
    end
    params[:s].delete(:like)
  end
  
  def like_value(v)
    return v if v.index("%") || v.index("_")
    "%#{v}%"
  end

  def date_search
    return unless params[:s][:date]
    simple_query(params[:s][:date]).each do |k,v|
      arr = v.split(",").delete_if{|x| x==''}
      if arr.size==1
        if v[0]==',' ||  v[-1]==','
          v1 = DateTime.parse(arr[0])
          operator = (v[0]==","?  "<=" : ">=")
          v1 = v1.end_of_day if v[0]==','
          @list = @list.where("#{k} #{operator} ?", v1)
        else
          day = DateTime.parse(arr[0])
          @list = @list.where(k => day.beginning_of_day..day.end_of_day)
        end
      elsif arr.size==2
        day1 = DateTime.parse(arr[0])
        day2 = DateTime.parse(arr[1])
        @list = @list.where(k => day1.beginning_of_day..day2.end_of_day)
      else
        logger.warn("date search 错误: #{k},#{v}")
      end
    end
    with_dot_query(params[:s][:date]).each do |k,v|
      model, field = k.split(".")
      @list = @list.joins(model.to_sym)
      arr = v.split(",").delete_if{|x| x==''}
      if arr.size==1
        if v[0]==',' ||  v[-1]==','
          logger.warn("date search 错误: #{k},#{v}. 外键字段暂不支持带,的单边日期查询")
        else
          day = DateTime.parse(arr[0])
          hash = {(model.pluralize) => { field => day.beginning_of_day..day.end_of_day}}
          @list = @list.where(hash)
        end
      elsif arr.size==2
        day1 = DateTime.parse(arr[0])
        day2 = DateTime.parse(arr[1])
        hash = {(model.pluralize) => { field => day1.beginning_of_day..day2.end_of_day}}
        @list = @list.where(hash)
       else
        logger.warn("date search 错误: #{k},#{v}")
      end
    end
    params[:s].delete(:date)
  end

  def range_search
    return unless params[:s][:range]
    simple_query(params[:s][:range]).each do |k,v|
      arr = v.split(",").delete_if{|x| x==''}
      if arr.size==1
        v1 = arr[0].to_f
        operator = (v[0]==","?  "<=" : ">=")
        @list = @list.where("#{k} #{operator} ?", v1)
      elsif arr.size==2
        v1 = arr[0].to_f
        v2 = arr[1].to_f
        @list = @list.where(k => v1..v2)
      else
        logger.warn("range search 错误: #{k},#{v}")
      end
    end
    with_dot_query(params[:s][:range]).each do |k,v|
      model, field = k.split(".")
      @list = @list.joins(model.to_sym)
      arr = v.split(",")
      if arr.size==1
        v1 = arr[0].to_f
        operator = (v[0]==","?  "<=" : ">=")
        @list = @list.where("#{model.pluralize}.#{field} #{operator} ?", v1)
      elsif arr.size==2
        v1 = arr[0].to_f
        v2 = arr[1].to_f
        hash = {(model.pluralize) => { field => v1..v2}}
        @list = @list.where(hash)
      else
        logger.warn("range search 错误: #{k},#{v}")
      end
    end
    params[:s].delete(:range)      
  end   

  def in_search
    return unless params[:s][:in]
    simple_query(params[:s][:in]).each do |k,v|
      arr = v.split(",")
      @list = @list.where("#{k} in (?)", arr)
    end
    with_dot_query(params[:s][:in]).each do |k,v|
      model, field = k.split(".")
      @list = @list.joins(model.to_sym)
      arr = v.split(",")
      @list = @list.where("#{model.pluralize}.#{field} in (?)", arr)
    end
    params[:s].delete(:in)      
  end 

  def cmp_search
    return unless params[:s][:cmp]
    simple_query(params[:s][:cmp]).each do |key,v|
      ["!=","<=",">=","=","<",">"].each do |op|
        if key.match(op)
          arr = key.split(op)
          next if arr.size != 2
          @list = @list.where("#{arr[0]} #{op} #{arr[1]}")
          break
        end
      end
    end
    with_dot_query(params[:s][:cmp]).each do |k,v|
      model, field = k.split(".")
      @list = @list.joins(model.to_sym)
      ["!=","<=",">=","=","<",">"].each do |op|
        if field.match(op)
          arr = field.split(op)
          next if arr.size != 2
          @list = @list.where("#{model.pluralize}.#{arr[0]} #{op} #{arr[1]}")
          break
        end
      end
    end
    params[:s].delete(:cmp)      
  end 
  
  def exists_search
    return unless params[:s][:exists]
    params[:s][:exists].each do |key,v|
      arel = @model_clazz.arel_table
      fid = @model_clazz.name.singularize.underscore+"_id"
      sql = Object.const_get(key.camelize.singularize).select(fid.to_sym).to_sql
      if v=="0"
        @list = @list.where(arel[:id].not_in(Arel.sql(sql)))
      elsif v=="1"
        @list = @list.where(arel[:id].in(Arel.sql(sql)))
      else
        raise "exists search only support 0/1 value"
      end
    end
    params[:s].delete(:exists)      
  end
  
  
  def with_dot_query(hash)
    hash.select{|k,v| k.index(".")}
  end
  
  def with_comma_query(hash)
    hash.select{|k,v| k.index(",")}
  end

  def simple_query(hash)
    hash.select{|k,v| !k.index(".") && !k.index(",")}
  end
  
  
  def check_search_param_exsit(hash,clazz)
    attrs = clazz.attribute_names
    %w{like date range in cmp exists}.each do |op|
      next unless hash[op]
      hash[op].each do |k,v|
        if op == 'exists'
          check_many_relation(k)
        else
          check_keys_exist(k, attrs, clazz, op)
        end
      end
      hash.delete(op)
    end
    hash.each{|k,v| check_keys_exist(k, attrs, clazz)}
  end
  
  def check_keys_exist(keys, attrs, clazz, op=nil)
    if keys.index(",")
      keys.split(",").each{|x| check_field_exist(x, attrs)}
    elsif keys.index(".")
      model, field = keys.split(".")
      if op == 'cmp'
        ["!=","<=",">=","=","<",">"].each{|x| field = field.split(x)[0]}
      end
      if model.singularize == model
        # 关联主表 belongs关系
        check_field_exist(model+"_id", attrs)
        clazz_name = clazz.get_belongs_class_name(model)
        check_field_exist(field, Object.const_get(clazz_name).attribute_names)
      else
        check_many_relation(model)
        clazz_name = model.camelize.singularize
        check_field_exist(field, Object.const_get(clazz_name).attribute_names)
      end
      #TODO: 跨库的join查询，数据库不支持
    else
      check_field_exist(keys, attrs)
    end
  end
  
  def check_field_exist(field, attrs)
    find = attrs.find{|x| x==field}
    raise "field:#{field} doesn't exists." unless find
  end
  
  def check_many_relation(key)
    manys = $many[@model_clazz.table_name.singularize]
    unless manys.find{|x| x==key.singularize}
      raise "#{@model_clazz.table_name} and #{key} hasn't one-to-many relation."
    end
  end
  
  
  def batch_update
    raise "only support json input" unless request.format == 'application/json'
    input = params[self.controller_name.to_sym]
    clazz_name = self.controller_name.singularize.camelize
    clazz = Object.const_get clazz_name
    ret = []
    if input.class == Array
      ActiveRecord::Base.transaction do
        input.each do |hash|
          id = hash[:id]
          hash.delete(:id)
          ret << clazz.find(id).update_attributes!(hash.permit!)
        end
      end
    else
      raise 'batch_update no longer support hash input, use array instead.'
    end
    # clazz.update(hash.keys, hash.values)  #本update方法无法报告异常，所以弃用
    render :json => {count: ret.size, updated:true}.to_json
  end
  
  
end
