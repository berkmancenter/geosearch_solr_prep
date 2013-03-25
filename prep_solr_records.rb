#!/usr/bin/env ruby

require 'bundler/setup'
require 'optparse'
require 'json/ext'
require 'nokogiri'
require 'geohash'
require 'csv'
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
            @geo_tag['anchor']              = attrs['Anchor']
            # Find the field in which the geotag occurs
            matches = nil
            # Get index of anchor start when json string is reversed
            start_index = $contents.length - @geo_tag['anchor_end'] - 1
            until matches
                # Grab up until the start of the line
                term_and_field_range = (start_index..$stnetnoc.index(/$/, start_index))
                term_and_field = $stnetnoc.slice(term_and_field_range).reverse
                matches = /"([.a-zA-Z0-9_]*)" : /.match(term_and_field)
                start_index = term_and_field_range.end + 1
            end
            @geo_tag['in_field'] = matches[1]
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
            @disjunct["geo_hash"] = GeoHash.encode(attrs['Latitude'].to_f, attrs['Longitude'].to_f, precision=12)
        end
    end

    def end_element name
        if @json_index
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
end

class String
    def clean
        CGI::escapeHTML(self.gsub(/\A[^\[\w\(]+|[^\w\)\]]+\z/, '')).strip
    end
end

options = {
    :forced_encoding => '',
    :template => '',
    :input_type => 'libcloud',
    :json_input => '',
    :geotag_input => '',
    :output_dir => '.'
    }

opt_parser = OptionParser.new do |opt|
    opt.banner = "Usage: prep_solr_records.rb [OPTIONS]"
    opt.separator ""
    opt.separator "Options"
    opt.separator ""

    opt.on('-o', '--output-dir DIR', 'the output directory') do |output|
        options[:output_dir] = output
    end

    opt.on('-i', '--input-type [TYPE]', 'the json input record type ("dpla" or "libcloud")') do |input_type|
        options[:input_type] = input_type
    end

    opt.on('-j', '--json-input [FILE]', 'the json input file') do |json_input|
        options[:json_input] = json_input
    end

    opt.on('-g', '--geotag-input [FILE]', 'the geotag xml input file') do |geotag_input|
        options[:geotag_input] = geotag_input
    end

    opt.on("-t","--template [TEMPLATE]","the template file to fill in") do |template|
        options[:template] = template
    end

    opt.on("-e","--encoding [ENCODING]","the encoding into which the output records are coerced") do |encoding|
        options[:forced_encoding] = encoding
    end

    opt.on("-h","--help","help") do
        puts opt_parser
        exit
    end
    opt.separator ""
end

opt_parser.parse!
if options[:input_type].empty? or options[:output_dir].empty? or options[:output_dir] == '.'
    puts opt_parser
    exit
end
unless ['dpla', 'libcloud'].include? options[:input_type]
    puts 'Input type must be one of "dpla" or "libcloud"'
    puts opt_parser
    exit
end
if options[:json_input].empty?
    options[:json_input] = "sample_files/#{options[:input_type]}_records.json"
end
if options[:geotag_input].empty?
    options[:geotag_input] = "sample_files/#{options[:input_type]}_geotags.xml"
end
if options[:template].empty?
    options[:template] = "#{options[:input_type]}_solr_record_template.xml.erb"
end

# Get JSON input
$contents = File.open(options[:json_input], 'r:bom|utf-8').read
end_chars = []

# Find the record boundaries and keep track of the last index of each
case options[:input_type]
when "dpla"
    $contents.to_enum(:scan,/"dpla\.title" : "[^"]*"\s*\}/).map do |m,|
        end_chars << $`.size + m.length - 1
    end
when "libcloud"
    $contents.to_enum(:scan,/ \}/).map do |m,|
        end_chars << $`.size
    end
end

$stnetnoc = $contents.reverse

# Strip out characters not defined in our encoding
unless options[:forced_encoding].empty?
    contents = $contents.encode(Encoding.find(options[:forced_encoding]), {
        :invalid           => :replace,  # Replace invalid byte sequences
        :undef             => :replace,  # Replace anything not defined in ASCII
        :replace           => ''         # Use a blank for those replacements
    })
else
    contents = $contents
end

# Get parsed JSON records
$json_contents = JSON.parse(contents)

# Parse the GeoTagger results and built up the internal data structure
parser = Nokogiri::XML::SAX::Parser.new(GeoTags.new(end_chars))
parser.parse(File.open(options[:geotag_input]))

erb_template = ERB.new(File.read(options[:template]))

# Make a nice variable for the template
docs = $json_contents['docs']

# Fill out the template and remove empty lines
records = erb_template.result(binding).gsub(/^\s*\n/,'')
fields = ERB.new(File.read('libcloud_csv_template.csv.erb')).result(binding)

# Split the template output into an array and save each record as a separate file
output_prefix = File::basename(options[:json_input], File::extname(options[:json_input]))
records = records.split(/<\/add>/)
records.each_with_index do |record, i|
    if i != records.length - 1
        output_suffix = i
        filename = "#{options[:output_dir].gsub(/\/$/,'')}/#{output_prefix}_rec_#{output_suffix}.xml"
        while File::exists?(filename)
            output_suffix = output_suffix.is_a?(Integer) ? "#{output_suffix}a" : output_suffix.succ
            filename = "#{options[:output_dir].gsub(/\/$/,'')}/#{output_prefix}_rec_#{output_suffix}.xml"
        end
        File.open(filename, 'w') { |f| f.write((record + '</add>').strip) }
    end
end
CSV.open("#{options[:output_dir].gsub(/\/$/,'')}/docs.csv", 'wb') do |csv|
    csv << [
'RecId', 'primLoc', 'cLoc1', 'cLoc2', 'cLoc3', 'id', 'title', 'title_sort',
'title_link_friendly', 'sub_title', 'creator', 'publisher', 'pub_location',
'pub_date', 'pub_date_numeric', 'format', 'language', 'pages', 'pages_numeric',
'height', 'height_numeric', 'lcsh', 'note', 'toc', 'call_num', 'id_inst',
'id_isbn', 'id_lccn', 'id_oclc', 'rsrc_key', 'rsrc_value', 'wp_categories',
'online_avail', 'holding_libs', 'ut_id', 'ut_count', 'loc_call_num_sort_order',
'loc_call_num_subject', 'url', 'data_source', 'dataset_tag', 'shelfrank',
'score_checkouts_undergrad', 'score_checkouts_grad', 'score_checkouts_fac',
'score_reserves', 'score_recalls', 'score_course_texts', 'score_holding_libs',
'score_extra_copies', 'score_total', 'title_exact', 'creator_exact',
'lcsh_exact', 'wp_categories_exact', 'title_keyword', 'creator_keyword',
'subject_keyword', 'note_keyword', 'keyword', 'Match_Confidence',
'Geocoded_Field', 'Anchor', 'Disjunct_Weight1', 'Conjunct_Name1',
'Conjunct_Country1', 'Conjunct_CountryName1', 'Conjunct_CountryConfidence1',
'Conjunct_Province1', 'Conjunct_ProvinceName1', 'Conjunct_ProvinceConfidence1',
'Conjunct_Latitude1', 'Conjunct_Longitude1', 'geo_hash12_1', 'geo_hash10_1',
'geo_hash8_1', 'geo_hash6_1', 'geo_hash4_1', 'geo_hash3_1', 'geo_hash2_1',
'Disjunct_Weight2', 'Conjunct_Name2', 'Conjunct_Country2',
'Conjunct_CountryName2', 'Conjunct_CountryConfidence2', 'Conjunct_Province2',
'Conjunct_ProvinceName2', 'Conjunct_ProvinceConfidence2', 'Conjunct_Latitude2',
'Conjunct_Longitude2', 'geo_hash12_2', 'geo_hash10_2', 'geo_hash8_2',
'geo_hash6_2', 'geo_hash4_2', 'geo_hash3_2', 'geo_hash2_2', 'Disjunct_Weight3',
'Conjunct_Name3', 'Conjunct_Country3', 'Conjunct_CountryName3',
'Conjunct_CountryConfidence3', 'Conjunct_Province3', 'Conjunct_ProvinceName3',
'Conjunct_ProvinceConfidence3', 'Conjunct_Latitude3', 'Conjunct_Longitude3',
'geo_hash12_3', 'geo_hash10_3', 'geo_hash8_3', 'geo_hash6_3', 'geo_hash4_3',
'geo_hash3_3', 'geo_hash2_3'
    ]
    fields.split("\n<doc-end>\n").each do |doc|
       csv << doc.split("\n")
    end
end
