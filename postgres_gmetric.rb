#!/usr/bin/ruby
# Queries a PostgreSQL database and publishes statistics to Ganglia using gmetric.
#
# == Install Dependencies ==
#
# sudo apt-get install ruby ganglia-monitor build-essential
#
# == Usage ==
#
# postgres_gmetric.rb <databasename>
#
# Author: Nicolas Marchildon <nicolas@marchildon.net>
# Date: 2009-07
# http://github.com/elecnix/postgres_gmetric
require 'optparse'

(puts "FATAL: gmetric not found" ; exit 1) if !File.exists? "/usr/bin/gmetric"

$options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Usage: postgres_gmetric.rb [-U <user>] <database>"

  # Define the options, and what they do
  $options[:verbose] = false
  opts.on( '-v', '--verbose', 'Output collected data' ) do
    $options[:verbose] = true
  end

  $options[:user] = ENV['LOGNAME']
  opts.on( '-U', '--user USER', 'Connect as USER' ) do |user|
    $options[:user] = user
  end

  opts.on( '-h', '--help', 'Display this screen' ) do
    puts opts
    exit
  end
end
optparse.parse!

$options[:database]=ARGV[0]

(puts "Missing database"; exit 1) if $options[:database].empty?
(puts "Missing user"; exit 1) if $options[:user].nil?

def query(sql)
  `psql -U #{$options[:user]} #{$options[:database]} -A -c "#{sql}"`
end

def publish(sql)
  data=query(sql)
  lines=data.split("\n")
  values=lines[1].split('|')
  lines[0].split('|').each_with_index do |colname, idx|
    v=values[idx]
    puts "#{colname}=#{v}" if $options[:verbose]
    `gmetric --group postgresql --name "pg_#{colname}" --value #{v} --type float --dmax=240`
  end
end

publish "select * from pg_stat_bgwriter;"
publish "select sum(numbackends) as backends, sum(xact_commit) as xact_commit, sum(xact_rollback) as xact_rollback, sum(blks_read) as blks_read, sum(blks_hit) as blks_hit, sum(tup_returned) as tup_returned, sum(tup_fetched) as tup_fetched, sum(tup_inserted) as tup_inserted, sum(tup_updated) as tup_updated, sum(tup_deleted) as tup_deleted from pg_stat_database;"
publish "select sum(seq_scan) as seq_scan, sum(seq_tup_read) as seq_tup_read, sum(idx_scan) as idx_scan, sum(idx_tup_fetch) as idx_tup_fetch, sum(n_tup_ins) as n_tup_ins, sum(n_tup_upd) as n_tup_upd, sum(n_tup_del) as n_tup_del, sum(n_tup_hot_upd) as n_tup_hot_upd, sum(n_live_tup) as n_live_tup, sum(n_dead_tup) as n_dead_tup from pg_stat_all_tables;"
publish "select sum(heap_blks_read) as heap_blks_read, sum(heap_blks_hit) as heap_blks_hit, sum(idx_blks_read) as idx_blks_read_tbl, sum(idx_blks_hit) as idx_blks_hit_tbl, sum(toast_blks_read) as toast_blks_read, sum(toast_blks_hit) as toast_blks_hit, sum(tidx_blks_read) as tidx_blks_read, sum(tidx_blks_hit) as tidx_blks_hit from pg_statio_all_tables;"
publish "select sum(idx_blks_read) as idx_blks_read, sum(idx_blks_hit) as idx_blks_hit from pg_statio_all_indexes;"
publish "select COALESCE(sum(blks_read), 0) as seq_blks_read, COALESCE(sum(blks_hit), 0) as seq_blks_hit from pg_statio_all_sequences;"
# publish check_postgres bloat
publish "SELECT sum(pg_database_size(d.oid)) as size_database FROM pg_database d ORDER BY 1 DESC LIMIT 10;"
publish "SELECT sum(pg_relation_size(c.oid)) as size_table FROM pg_class c, pg_namespace n WHERE (relkind = 'r') AND n.oid = c.relnamespace;"
publish "SELECT sum(pg_relation_size(c.oid)) as size_index FROM pg_class c, pg_namespace n WHERE (relkind = 'i') AND n.oid = c.relnamespace;"
publish "SELECT sum(pg_relation_size(c.oid)) as size_relation FROM pg_class c, pg_namespace n WHERE (relkind = 'i' OR relkind = 'r') AND n.oid = c.relnamespace;"
publish "select count(*) as backends_waiting from pg_stat_activity where waiting = 't';"
publish "SELECT (SELECT count(*) FROM pg_locks) as locks"
publish "SELECT COALESCE(max(COALESCE(ROUND(EXTRACT(epoch FROM now()-query_start)),0)),0) as query_time_max FROM pg_stat_activity WHERE current_query <> '<IDLE>';"
publish "SELECT COALESCE(max(COALESCE(ROUND(EXTRACT(epoch FROM now()-query_start)),0)),0) as query_time_idle_in_txn FROM pg_stat_activity WHERE current_query = '<IDLE> in transaction';"
publish "SELECT max(COALESCE(ROUND(EXTRACT(epoch FROM now()-xact_start)),0)) as txn_time_max FROM pg_stat_activity WHERE xact_start IS NOT NULL;"
publish "SELECT max(age(datfrozenxid)) as datfrozenxid_age FROM pg_database WHERE datallowconn;"
publish "SELECT count(*) as wal_files FROM pg_ls_dir('pg_xlog') WHERE pg_ls_dir ~ E'^[0-9A-F]{24}$';"
["vacuum", "analyze"].each do |type|
  ["auto", ""].each do |auto|
    criteria = (auto == "auto") ? "pg_stat_get_last_auto#{type}_time(c.oid)" : "GREATEST(pg_stat_get_last_#{type}_time(c.oid), pg_stat_get_last_auto#{type}_time(c.oid))"
    publish "SELECT max(CASE WHEN v IS NULL THEN -1 ELSE round(extract(epoch FROM now()-v)) END) as #{auto}#{type}_age FROM (SELECT nspname, relname, #{criteria} AS v FROM pg_class c, pg_namespace n WHERE relkind = 'r' AND n.oid = c.relnamespace AND n.nspname <> 'information_schema' ORDER BY 3) AS foo;"
  end
end

