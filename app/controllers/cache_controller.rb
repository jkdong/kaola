class CacheController < ApplicationController
  def expire
    table = params[:tables]
    raise "table doesn't exsits." unless table
    table.split(',').each do |t|
      if $tables.find{|x| x==t}
        clear_cache(t, params[:syn] == "1")
      else
        raise "table #{table} doesn't exsits."
      end
    end
    if ENV["rb_servers"]
      ENV["rb_servers"].split(',').each do |host|
        RestClient.post "http://#{host}/cache/expire", {tables: table, syn: "1"}
      end
    end
    render :json => {status:"ok"}.to_json
  end

  def expire_all
    $tables.each do |table|
      clear_cache(t, params[:syn] == "1")
    end
    if ENV["rb_servers"]
      ENV["rb_servers"].split(',').each do |host|
        RestClient.post "http://#{host}/cache/expire", {syn: "1"}
      end
    end
    render :json => {status:"ok"}.to_json
  end
  
  private
  
  def clear_cache(table, syn)
    clazz_name = table.singularize.camelize
    clazz = Object.const_get(clazz_name)
    if syn
      clazz.init_prefix
    else
      clazz.inc_prefix
    end
  end
    
end