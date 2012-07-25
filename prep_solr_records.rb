#!/usr/bin/env ruby

require 'optparse'
require 'json/ext'
require 'nokogiri'
require 'erb'
require 'cgi'

class GeoTags < Nokogiri::XML::SAX::Document

    def initialize end_chars
        @end_chars = end_chars
        @geo_tag = { 'disjuncts' => [] }
    end

    def start_element name, attrs = []
        attrs = Hash[attrs]
        case name
        when 'GeoTag'
            @geo_tag['confidence']          = attrs['Confidence']
        when 'TextExtent'
            @geo_tag['anchor_start']        = attrs['AnchorStart'].to_i
            @geo_tag['anchor_end']          = attrs['AnchorEnd'].to_i
            @json_index = @end_chars.find_index { |end_char| @geo_tag['anchor_end'] < end_char }
        when 'Disjunct'
            @disjunct                        = {}
            @disjunct['weight']              = attrs['Weight']
        when 'Conjunct'
            @disjunct['name']                = attrs['Name']
            @disjunct['country']             = attrs['Country'] if attrs['Country']
            @disjunct['country_name']        = attrs['CountryName'] if attrs['CountryName']
            @disjunct['country_confidence']  = attrs['CountryConfidence'] if attrs['CountryConfidence']
            @disjunct['province']            = attrs['Province'] if attrs['Province']
            @disjunct['province_name']       = attrs['ProvinceName'] if attrs['ProvinceName']
            @disjunct['province_confidence'] = attrs['ProvinceConfidence'] if attrs['ProvinceConfidence']
        when 'Dot'
            @disjunct['latitude']            = attrs['Latitude']
            @disjunct['longitude']           = attrs['Longitude']
        end
    end

    def end_element name
        case name
        when 'GeoTag'
            $json_contents['docs'][@json_index]['geotags'] = [] if !$json_contents['docs'][@json_index]['geotags']
            $json_contents['docs'][@json_index]['geotags'] << @geo_tag
            @geo_tag = { 'disjuncts' => [] }
        when 'Disjunct'
            @geo_tag['disjuncts'] << @disjunct if @geo_tag['disjuncts'].length < 3
        end
    end
end

class String
    def clean
        CGI::escapeHTML(self.gsub(/\A[^\[\w\(]+|[^\w\)\]]+\z/, ''))
    end
end

options = {
    :forced_encoding => 'ASCII',
    :template => 'solr_record_template.xml.erb',
    :json_input => '',
    :geotag_input => '',
    :output_dir => '.'
    }

opt_parser = OptionParser.new do |opt|
    opt.banner = "Usage: prep_solr_records.rb [OPTIONS]"
    opt.separator ""
    opt.separator "Options"
    opt.separator ""

    opt.on('-j', '--json-input FILE', 'the json input file') do |json_input|
        options[:json_input] = json_input
    end

    opt.on('-g', '--geotag-input FILE', 'the geotag xml input file') do |geotag_input|
        options[:geotag_input] = geotag_input
    end

    opt.on('-o', '--output-dir DIR', 'the output directory') do |output|
        options[:output_dir] = output
    end

    opt.on("-e","--encoding [ENCODING]","the encoding into which the output records are coerced") do |encoding|
        options[:forced_encoding] = encoding
    end

    opt.on("-t","--template [TEMPLATE]","the template file to fill in") do |template|
        options[:template] = template
    end

    opt.on("-h","--help","help") do
        puts opt_parser
        exit
    end
    opt.separator ""
end

opt_parser.parse!
if options[:json_input].empty? or options[:geotag_input].empty? or options[:output_dir].empty?
    puts opt_parser
    exit
end

contents = File.read options[:json_input]
end_chars = []
contents.to_enum(:scan,/"dpla\.title" : "[^"]*"\s*\}/).map do |m,|
    end_chars << $`.size + m.length - 1
end

contents = contents.encode(Encoding.find(options[:forced_encoding]), {
    :invalid           => :replace,  # Replace invalid byte sequences
    :undef             => :replace,  # Replace anything not defined in ASCII
    :replace           => ''        # Use a blank for those replacements
  }
)

$json_contents = JSON.parse(contents)

parser = Nokogiri::XML::SAX::Parser.new(GeoTags.new(end_chars))
parser.parse(File.open(options[:geotag_input]))

erb_template = ERB.new(File.read(options[:template]))

docs = $json_contents['docs']
records = erb_template.result(binding).gsub(/^\s*\n/,'')
records = records.split(/<\/add>/)
records.each_with_index do |record, i|
    if i != records.length - 1
        File.open("#{options[:output_dir].gsub(/\/$/,'')}/record#{i}.xml", 'w') { |f| f.write((record + '</add>').strip) }
    end
end
