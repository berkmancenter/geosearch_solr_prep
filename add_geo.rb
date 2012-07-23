require 'json/ext'
require 'nokogiri'
require 'liquid'
require 'pp'
require 'erb'

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

module MyFilters
    def clean(input)
        input.gsub(/\A[^\[\w\(]+|[^\w\)\]]+\z/, '') if input
    end
end

class String
    def clean
        self.gsub(/\A[^\[\w\(]+|[^\w\)\]]+\z/, '')
    end
end

Liquid::Template.register_filter(MyFilters)

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
template = Liquid::Template.parse(File.read('solr_record_template.xml.liquid'))
erb_template = ERB.new(File.read('solr_record_template.xml.erb'))

docs = $json_contents['docs']
records = erb_template.result(binding)
# $json_contents['docs'].each do |doc|
#     doc['geotags'].each do |geotag|
# #        rendered = template.render(
# #            'geotag' => geotag,
# #            'doc' => doc,
# #            'json' => doc.to_json,
# #            'marc_fields' => [
# #                '100a', '100c', '100d', '245a', '245c', '260a', '260b', '260c',
# #                '300a', '300c', '500a', '655a', '700a', '700d', '700e', '752a',
# #                '752d', '440a', '440p', '830a', '830p', '840a', '130a', '730a',
# #                '240a', '260f', '260e', '752b', '034d', '034e', '034f', '034g',
# #                '245b', '245c', '245p', '246a', '740a', '600y', '610y', '611y',
# #                '630y', '650y', '651y', '655y', '690y', '691y', '692y', '693y',
# #                '694y', '695y', '600v', '610v', '611v', '630v', '650v', '651v',
# #                '655b', '655v', '690v', '691v', '692v', '693v', '694v', '695v'
# #            ]
# #        )
#         records += erb_template.result(binding)
#     end
# end
File.open("output/test2.xml", 'w') { |f| f.write(records) }
