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
            @disjunct['country']             = attrs['Country']
            @disjunct['country_name']        = attrs['CountryName']
            @disjunct['country_confidence']  = attrs['CountryConfidence']
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
            @geo_tag['disjuncts'] << @disjunct
        end
    end
end

class String
    def clean
        CGI::escapeHTML(self.gsub(/\A[^\[\w\(]+|[^\w\)\]]+\z/, ''))
    end
end

contents = File.read 'sample_files/dpla_records.json'
end_chars = []
contents.to_enum(:scan,/"dpla\.title" : "[^"]*"\s*\}/).map do |m,|
    end_chars << $`.size + m.length - 1
end

contents = contents.encode(Encoding.find('ASCII'), {
    :invalid           => :replace,  # Replace invalid byte sequences
    :undef             => :replace,  # Replace anything not defined in ASCII
    :replace           => ''        # Use a blank for those replacements
  }
)

$json_contents = JSON.parse(contents)

parser = Nokogiri::XML::SAX::Parser.new(GeoTags.new(end_chars))
parser.parse(File.open('sample_files/geotags.xml'))

erb_template = ERB.new(File.read('solr_record_template.xml.erb'))

docs = $json_contents['docs']
records = erb_template.result(binding).gsub(/^\s*\n/,'')
records = records.split(/<\/add>/)
records.each_with_index do |record, i|
    if i != records.length - 1
        File.open("output/collection/record#{i}.xml", 'w') { |f| f.write((record + '</add>').strip) }
    end
end
