#!/usr/bin/ruby
require 'googleapi.rb'
@api = GoogleAPI.new('joecaswell.info')
@api.login
@api.cli
