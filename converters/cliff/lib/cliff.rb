# encoding: utf-8
#
# RedmineMorePreviews converter to text files
#
# Copyright © 2020 Stephan Wenzel <stephan.wenzel@drwpatent.de>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#

require "nokogiri"
require 'active_support/core_ext/hash/conversions'

class Cliff < RedmineMorePreviews::Conversion

  #---------------------------------------------------------------------------------------
  # libraries
  #---------------------------------------------------------------------------------------
  include RedmineMorePreviews::Lib
  
  #---------------------------------------------------------------------------------------
  # delegates
  #---------------------------------------------------------------------------------------
  delegate :number_to_human_size, :link_to, :to => "ApplicationController.helpers"
  delegate :url_for, :to => "Rails.application.routes.url_helpers"
  
  #---------------------------------------------------------------------------------------
  # limits
  #---------------------------------------------------------------------------------------
  # Mail parses the whole message into objects, part by part, and every attachment
  # is written out: an email of many small parts takes memory and time far beyond
  # its size. The size (MiB) and the number of MIME parts are checked on the raw
  # text before it is parsed, the attachments beyond the limit are listed only.
  # A converter setting overrides each default.
  LIMITS         = {'max_size' => 50, 'max_parts' => 1000, 'max_attachments' => 1000}.freeze
  
  # nested multipart parts: Mail's helpers (attachments, html_part, ...) walk
  # the whole tree again and again, in more than linear time in its depth,
  # and Mail keeps the body of every level, so the bodies parsed add up to
  # the size of the email times the depth. Both are bounded, the bodies by a
  # multiple of the size limit
  MAX_DEPTH      = 100
  MAX_PARSED     = 5
  
  # Mail's patterns keep state for every byte of some header lines, some 50
  # times the email in memory, and nothing short of parsing tells which: the
  # email is parsed in a child process with this much memory (see
  # Conversion#isolated)
  MAX_MEMORY     = 1024 * 1024 * 1024
  
  ########################################################################################
  #
  # convert
  #
  ########################################################################################
  def convert
    case preview_format
    when 'html'
      # what the child needs from the database is read here, before the fork
      LIMITS.each_key {|key| limit( key ) }
      object.to_h["object"].try( :project )
      isolated( :memory => max_memory ) { eml }
    end
  end #def
  
  ########################################################################################
  #
  # helpers
  #
  ########################################################################################
  
  #---------------------------------------------------------------------------------------
  # eml
  #---------------------------------------------------------------------------------------
  def eml
  
    # read eml file
    if File.size(source) > limit('max_size') * 1024 * 1024
      raise ConverterBadArgument, "the email is larger than #{limit('max_size')} MiB"
    end
    text  = RmpText.to_utf8(File.read(source))
    check_parts( text )
    mail  = Mail.new(text)
    check_depth( mail )
    
    # get html
    html, charset = html( mail )
    
    # sweep bad stuff from html
    unless unsafe
    html = sweep( html )
    end
    
    # save headers, users usually want to see
    save_headers( mail ) 
    
    # save headers, users may want to see
    save_fields( mail )
    
    if mail.attachments.any?
    
      # create an empty index.html file, which causes, that no extracted attachment is named likewise
      File.open(tmptarget, "w") {}
      
      # create an empty attachments.html file, which causes, that no extracted attachment is named likewise
      File.open(File.join(tmpdir, "attachments.html"), "wb") {}
    
      # save attachments( which will not collide with index.html and attachments.html)
      attachments = save_attachments( mail ) 
      omitted     = mail.attachments.size - attachments.size
      
      # modify cid:links in html and save 
      html = link( Nokogiri::HTML( html ), Array(attachments) ).to_html
      
      # create list of attachments and save
      att_html = list( attachments, omitted )
      attachments_path = File.join( File.dirname(tmptarget), "attachments.html")
      File.open(attachments_path, "wb") {|f| f.write att_html }
      
    end
    
    
    File.open(tmptarget, "wb") {|f| f.write html }
    
  rescue Exception => e
    # the message can quote the mail being parsed, so it is attacker controlled
    File.open(tmptarget, "wb") {|f| f.write (([e.message] + e.backtrace).map{|line| ERB::Util.html_escape(line)}.join("<br>\n")) }
  end #def
  
  #---------------------------------------------------------------------------------------
  # html
  #---------------------------------------------------------------------------------------
  def html( mail )
  
    if mail.content_type && mail.content_type.downcase =~ /multipart/
    
        ###########################################################
        #  multipart:                                             #
        ###########################################################
        
      if mail.html_part
        ###########################################################
        #  multipart: try to fetch html                           #
        ###########################################################
        encoding      = mail.html_part.content_transfer_encoding
        charset       = mail.html_part.charset
        
        if encoding =~ /quoted-printable/ # there is a bug in .decoded
          html        = mail.html_part.body.to_s.unpack('M')[0].html_safe
        else
          html        = mail.html_part.body.decoded
        end
        
        ###########################################################
        #  get eventual charset: UTF-8, Windows-1252, etc.        #
        #  careful: 'charset' in mail is 'encoding' for strings   #
        ###########################################################
        charset     ||= RmpText.get_charset( html )
      
      elsif mail.text_part 
        ###########################################################
        #  multipart: no html -> try to fetch text                #
        ###########################################################
        encoding      = mail.text_part.content_transfer_encoding
        charset       = mail.text_part.charset
        
        if encoding =~ /quoted-printable/ # there is a bug in .decoded
          text        = mail.text_part.body.to_s.unpack('M')[0]
          text        = RmpText.to_utf8(text, charset)
        else
          text        = mail.text_part.body.decoded
        end
        
        @text         = text
        erb           = ERB.new(File.read(File.join(views, 'cliff', 'pre.html.erb')))
        html          = erb.result(binding).html_safe
        charset       = "UTF-8"
        
      else
        ###########################################################
        #  multipart: no html, no text -> empty message part      #
        ###########################################################
        @text         = ""
        erb           = ERB.new(File.read(File.join(views, 'cliff', 'pre.html.erb')))
        html          = erb.result(binding).html_safe
        charset       = 'UTF-8'
      end
    else
    
        ###########################################################
        #  single part:                                           #
        ###########################################################
      
      if mail.content_type && mail.content_type.downcase =~ /text\/html/
        ###########################################################
        #  single part: try to identify html by content_type      #
        ###########################################################
        encoding      = mail.body.encoding
        charset       = mail.body.charset
        
        if encoding =~ /quoted-printable/ # there is a bug in .decoded
          html        = mail.body.to_s.unpack('M')[0].html_safe
        else
          html        = mail.body.decoded
        end
        
        ###########################################################
        #  get eventual encoding: UTF-8, Windows-1252, etc.       #
        #  careful: 'charset' in mail is 'encoding' for strings   #
        ###########################################################
        charset     ||= RmpText.get_charset( html )
        
      elsif mail.content_type && mail.content_type.downcase =~ /text\/plain/
        ###########################################################
        #  single part: text                                      #
        ###########################################################
        encoding      = mail.body.encoding
        charset       = mail.body.charset
        
        if encoding =~ /quoted-printable/ # there is a bug in .decoded
          text        = mail.body.to_s.unpack('M')[0]
          text        = RmpText.to_utf8(text, charset)
        else
          text        = mail.body.decoded
        end
        
        @text         = text
        erb           = ERB.new(File.read(File.join(views, 'cliff', 'pre.html.erb')))
        html          = erb.result(binding).html_safe
        charset       = "UTF-8"
        
      else
        ###########################################################
        #  single part: no html no text                           #
        ###########################################################
        @text         = ""
        erb           = ERB.new(File.read(File.join(views, 'cliff', 'pre.html.erb')))
        html          = erb.result(binding).html_safe
        charset       = 'UTF-8'
      end
    end 
    [html, charset]
  end #def
  
  #---------------------------------------------------------------------------------------
  # save_attachments
  #---------------------------------------------------------------------------------------
  def save_attachments( message )
    attachments      = {}
    # the names in use and the next index of each name, kept across attachments
    names, counters  = Set.new( Dir.children(tmpdir) ), {}
    message.attachments.each_with_index do | attachment, i |
      break if i >= limit('max_attachments')
      filename       = RmpFile.sanitize(attachment.filename)
      filename       = RmpFile.unique_filename( names, filename, :counters => counters )
      names         << filename
      content_id     = attachment.content_id.to_s.match(/^\<(.*?)\>$/)
      content_id   ||= [0, attachment.content_id.to_s]
      content_id     = content_id && content_id[1]
      attachments[i] = {:filename     => filename,
                        :content_id   => content_id,
                        :content_type => attachment.content_type
                        }
      File.open(File.join(tmpdir, filename), "w+b", 0644) {|f| f.write attachment.decoded}
    end 
    attachments 
  end #def
  
  #---------------------------------------------------------------------------------------
  # limits
  #---------------------------------------------------------------------------------------
  def max_memory
    MAX_MEMORY
  end #def
  
  def limit( key )
    @limits ||= {}
    @limits[key] ||= begin
      value = converter_settings[key].to_i
      value > 0 ? value : LIMITS[key]
    end
  end #def
  
  # a line starting with "--": Mail splits a part at a line of "--" and its
  # boundary, which it reads in forms no simple pattern follows (quoted, with
  # comments, RFC 2231, empty ...), after making every CR, LF or CRLF a line
  # break. Every such line is counted
  DELIMITER = /(?:\A|[\r\n])--/
  
  # the text Mail's pattern for an mbox "From " line runs over: "From", white
  # space (line breaks included), a character and the ASCII text after it, of
  # which the rest of the line is an upper bound. The pattern keeps
  # state for every byte it runs over, some 50 times the text in memory, so the
  # run is bounded by the longest line of a message (RFC 5322) first, on no
  # more of the text than that
  ENVELOPE      = /\AFrom\s*[^\r\n]*/n
  MAX_LINE      = 998
  
  # counts the delimiter lines of the raw message, an upper bound of the parts
  # Mail would parse, and stops at the first one beyond the limit
  def check_parts( text )
    if text.start_with?( "From" ) && text.byteslice( 0, MAX_LINE + 1 ).b[ENVELOPE].bytesize > MAX_LINE
      raise ConverterBadArgument, "the email starts with a \"From\" line longer than #{MAX_LINE} characters"
    end
    count = 0
    text.scan( DELIMITER ) do
      count += 1
      raise ConverterBadArgument, "the email has more than #{limit('max_parts')} parts" if count > limit('max_parts')
    end
  end #def
  
  # walks the parts as Mail reads them, before anything walks the whole tree:
  # Mail splits the body of a part only when its parts are asked for, so
  # nothing beyond the limits is parsed. Whether a part is multipart is Mail's
  # decision, not a guess from the raw text
  def check_depth( mail )
    budget = MAX_PARSED * limit('max_size') * 1024 * 1024
    parsed = 0
    stack  = [[mail, 1]]
    until stack.empty?
      part, depth = stack.pop
      next unless part.multipart?
      raise ConverterBadArgument, "the email has more than #{MAX_DEPTH} nested multipart parts" if depth > MAX_DEPTH
      parsed += part.body.raw_source.to_s.bytesize
      if parsed > budget
        raise ConverterBadArgument, "the nested multipart parts of the email add up to more than #{MAX_PARSED * limit('max_size')} MiB"
      end
      part.parts.each {|child| stack.push( [child, depth + 1] ) }
    end
  end #def
  
  #---------------------------------------------------------------------------------------
  # save_headers
  #---------------------------------------------------------------------------------------
  def save_headers( message )
    @mail      = message
    erb        = ERB.new(File.read(File.join(views, 'cliff', 'headers.html.erb')))
    headers    = erb.result(binding).html_safe
    File.open(File.join(tmpdir, "headers.html"), "w+b", 0644) {|f| f.write headers }
  end #def
  
  #---------------------------------------------------------------------------------------
  # save_headers
  #---------------------------------------------------------------------------------------
  def save_fields( message )
    @mail      = message
    erb        = ERB.new(File.read(File.join(views, 'cliff', 'fields.html.erb')))
    fields     = erb.result(binding).html_safe
    File.open(File.join(tmpdir, "fields.html"), "w+b", 0644) {|f| f.write fields }
  end #def
  
  #---------------------------------------------------------------------------------------
  # sweep
  #---------------------------------------------------------------------------------------
  UNSAFETAGS   = %w(script)
  
  def sweep( html )
  
    doc = Nokogiri::HTML(html)
    
    #
    # remove unsafe tags
    #
    UNSAFETAGS.each do |ust|
      doc.xpath("//*[self::#{ust}]").each do |node|
        node.remove
      end
    end
    
    #
    # remove link= attribute of style tags
    #
    doc.xpath("//style").each do |node|
      node.keys.each do |attribute|
        if attribute =~ /link/i
          node.delete attribute
        end
      end
    end
    
    #
    # remove url(.*) attribute within css style tags
    #
    doc.xpath("//style/text()").each do |node|
      node.replace(node.content.gsub(/url\(.*?\)/, ""))
    end
    
    #
    # remove url(.*) attribute within css style attributes
    #
    doc.xpath("//*").each do |node|
      node.keys.each do |attribute|
        if attribute =~ /style/i
          node[attribute] = node[attribute].to_s.gsub(/url\(.*?\)/, "")
        end
      end
    end
    
    #
    # remove src= attribute of external images
    #
    doc.xpath("//img").each do |node|
      node.keys.each do |attribute|
        if attribute =~ /src/i && node[attribute] !~ /\Acid:/i
          node.delete attribute
        end
      end
    end
    
    #
    # remove href= attribute of external links
    #
    doc.xpath("//a").each do |node|
      node.keys.each do |attribute|
        if attribute =~ /href/i
          node.delete attribute
        end
      end
    end
    
    #
    # remove unsafe event attributes beginning with "on…"
    #
    patterns = [
                 "//*[@*[starts-with(name(), 'on')]]",
                "//@*[@*[starts-with(name(), 'on')]]",
      "//namespace::*[@*[starts-with(name(), 'on')]]"
    ].join(" | ")
    doc.xpath(patterns).each do |node|
      node.keys.each do |attribute|
        node.delete attribute if attribute =~ /\Aon/i
      end
    end
    
    # to_html will automatically correct 
    # <meta http-equiv="Content-Type" content="text/html; charset=<CHARSET>"
    # took me a day to find that out
    doc.to_html
  end #def
  
  #---------------------------------------------------------------------------------------
  # link
  #---------------------------------------------------------------------------------------
  def link( xml, attachments )
    #
    # link src= attribute of images
    #
    xml.xpath("//img").each do |node|
      node.keys.each do |attribute|
        if attribute =~ /src/i && node[attribute] =~ /\Acid:/i
          cidmatch = node[attribute].match(/^cid:(.*)/i); cid = cidmatch && cidmatch[1]
          if att = attachments.find{|key,value| value && value[:content_id] == cid}
            node[attribute] = att[1][:filename]
          end
        end
      end
    end
    xml
  end #def
  
  #---------------------------------------------------------------------------------------
  # list 
  #---------------------------------------------------------------------------------------
  def list( attachments, omitted = 0 )
    b = binding
    b.local_variable_set(:attachments, attachments)
    b.local_variable_set(:omitted, omitted)
    b.local_variable_set(:object, object)
    erb = ERB.new(File.read(File.join(views, 'cliff', 'attachments.html.erb')))
    erb.result(b).squish.html_safe
  end #def
  
  #---------------------------------------------------------------------------------------
  # obj_to_xml( label, obj, xml=nil )
  # creates xml from an arbitrary nested mixture of arrays and hashes
  #
  def obj_to_xml( label, obj, xml=nil )
  
    if xml
      if obj.is_a?(Array)
        obj.each do |value|
          obj_to_xml(label,value,xml)     # Recurse
        end
      elsif obj.is_a?(Hash)
        if obj.any?
          xml.send(label) do
            obj.each do |key, value|
              obj_to_xml(key,value,xml)   # Recurse
            end
          end
        end
      else
        xml.send(label,obj)               # Create <label>obj(value)</label>
      end #if 
    else
      _xml = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.root do                       # Wrap everything in one element.
         obj_to_xml(label, obj ,xml)      # Start the recursion with a custom name.
        end #_xml
      end #Nokogiri
    end #if
    _xml
  end #def 
  
end #class
