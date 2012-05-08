#
# Copyright (C) 2012 Kyle Johnson <kyle@vacantminded.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

require 'date'
require 'uri'
require 'digest'

module IRCStats

  def self.run(filename, options)
    @nick_stats, @now = {}, Time.now.to_i
    @current_date, @start_time = "", 0
    @tmp_dir = `mktemp -d`.chomp

    @options = options

    @stats, @long_words = {}, {}

    @network, @channel = File.basename(filename).split(/\./)[1..2]

    read_file filename
    write_html

    clean
  end

  def self.clean
    `rm -r #{@tmp_dir}` if Dir.exists? @tmp_dir
  end

  def self.word_stats(arr)
    arr.each do |word|
      word.downcase!
      next if word.length < @options[:top_word_length]

      @long_words[word] ||= 0
      @long_words[word]  += 1
    end
  end

  def self.parse_line(file, size, line)
    unless line =~ /\A(\d{4})-(\d{2})-(\d{2})\s[\d:]{8}\t[@+&~!%]?([^\t]+)\t(.+)\Z/
      return
    end

    year, month, day = $1, $2, $3
    nick, text = $4, $5
    date = "%s%s%s" % [year, month, day]
    text_arr = text.split

    nick = text_arr.first if nick == " *"

    return if nick.include? ' ' or nick == "=!="

    case nick

    when "<--"
      nick = correct_nick(text_arr.shift)
      return if nick == nil or nick.empty? or nick.include? '*'

      @stats[nick] ||= IRCUser.new(nick, @tmp_dir)

      case text_arr[2]
      when "quit"
        @stats[nick].quits += 1

      when "left"
        @stats[nick].parts += 1

      else
        # kick
        @stats[nick].kicker += 1

        target = text_arr[2]
        @stats[target] ||= IRCUser.new(nick, @tmp_dir)
        @stats[target].kicked += 1

      end

      return

    when  "-->"
      nick = correct_nick(text_arr.shift)
      return if nick == nil or nick.empty? or nick.include? '*'

      @stats[nick] ||= IRCUser.new(nick, @tmp_dir)
      @stats[nick].joins += 1

      return

    when "--"
      return unless text_arr.shift == "Mode"

      nick = correct_nick(text_arr.last)
      return if nick == nil or nick.empty? or nick.include? '*'

      @stats[nick] ||= IRCUser.new(nick, @tmp_dir)
      @stats[nick].modes += 1

      return
    end

    nick = correct_nick(nick)

    return if nick == nil or nick.empty? or nick.include? '*'

    ts = Time.mktime(year, month, day).to_i

    unless date == @current_date
      @start_time   = ts - 1 if @current_date.empty? and not date.empty?
      @current_date = date

      if @current_date != nil and not @current_date.empty?
        write_progress_bar "Parsing", file.pos.to_f / size.to_f

        @nick_stats.each_pair do |my_nick, my_count|
          `rrdtool update '#{@tmp_dir}/#{my_nick}.rrd' #{ts}:#{my_count}`
        end
        
        @nick_stats = {}
      end
    end

    unless File.exists? "#{@tmp_dir}/#{nick}.rrd"
      `rrdtool create '#{@tmp_dir}/#{nick}.rrd' --step 86400 \
       --start #{@start_time} \
       DS:messages:GAUGE:86400:0:10000 \
       RRA:AVERAGE:0.5:1:365 \
       RRA:MAX:0.5:1:365`

       @stats[nick] ||= IRCUser.new(nick, @tmp_dir)
    end

    @nick_stats[nick] ||= 0
    @nick_stats[nick]  += 1

    word_stats text_arr
    @stats[nick].add_line(text)
  end

  def self.read_file(filename)
    raise "No such file: #{filename}" unless File.exists? filename

    size = File.size(filename)

    File.open(filename, "r") do |file|
      while line = file.gets do
        parse_line file, size, line.force_encoding('ASCII-8BIT').chomp
      end
    end

    write_progress_bar "Parsing", 1
    puts
  end

  def self.correct_nick(nick)
    nick.downcase!

    nick.sub!(/\[.+\]/, '') unless nick[0] == '['
    nick.sub!(/\{.+\}/, '') unless nick[0] == '{'
    nick.sub!(/\|.+$/, '')  unless nick[0] == '|'

    nick.gsub!(/[\[\]\\\|\^`\{\}-]/, '_')

    return nil if nick.empty? or nick[0] == '*' or nick[1] == '*'

    NICK_CHECKS.each do |check|
      if check.glob
        return check.nick if File.fnmatch(check.str, nick)
      else
        return check.nick if nick == check.str
      end
    end

    nick
  end


  # TODO: Rewrite this whole thing. It is held together with duct take and bad code.
  def self.write_html
    if @stats.empty?
      puts "No stats to write for %s %s. Skipping output." % [@channel, @network]
      return
    end

    write_progress_bar "Writing Output", 0

    long_words = @long_words.sort_by {|w, c| c * -1}.shift(@options[:top_word_count])

    mt = @options[:message_threshold]
    @stats.delete_if {|n, u| u.line_count < mt}

    my_output_dir = @options[:output_dir].dup
    Dir.mkdir my_output_dir unless Dir.exists? my_output_dir

    my_output_dir << "/%s/" % @network
    Dir.mkdir my_output_dir unless Dir.exists? my_output_dir

    my_output_dir << "%s/" % @channel

    `rm -r '#{my_output_dir}'` if Dir.exists? my_output_dir

    Dir.mkdir my_output_dir

    nick_list = @stats.keys.sort

    html = File.open("#{my_output_dir}/index.html", "w")
    html << " <!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">
<html><head><title>#{@channel} on #{@network}</title><meta http-equiv=\"Content-Type\" content=\"text/html;charset=utf-8\" ><style type=\"text/css\">
body {
  background-color: #999;
}
#content {
  background-color: #FFF;
  width: 950px;
  padding: 10px;
  margin: 10px auto;
  box-shadow: 10px 10px 10px #777;
  border-radius: 10px;
  text-align: center;
}
img {
  display: block;
  margin: 10px auto;
}
table {
  width: 825px;
  border: 0;
  margin: 10px auto;
}
th {
  background-color: #FFF;
}
tr {
  background-color: #DEDEDE;
}
tr:hover {
  background-color: #CCC;
}
tr a {
  text-decoration: none;
}
td.color {
  width: 25px;
}
#footer {
  width: 800px;
  text-align: center;
  margin: 5px auto;
}
</style></head><body><div id=\"content\"><h1>User Activity in #{@channel} on #{@network}</h1>
<p><em>Nicks are changed to lower case, some characters are replaced with underscores, and
some manual nick change correction is performed. Only users that have spoken at least
#{mt} lines are shown.</em></p>
<table><tr><th></th><th>Nick</th><th>Total Lines</th><th>Average Line Length</th><th>Words Per Line</th></tr>"

    areas, defs, = "", ""

    nick_list.each do |nick|
      html << '<tr><td class="color" style="background-color: #%s;"></td>' % @stats[nick].color
      html << '<td><a href="#%s">%s</a></td>' % [nick, nick]
      html << '<td>%d</td><td>%d</td>' % [@stats[nick].line_count, @stats[nick].average_line_length]
      html << '<td>%d</td></tr>' % @stats[nick].words_per_line

      areas << "%s " % @stats[nick].rrd_area
      defs  << "%s " % @stats[nick].rrd_def
    end

    html << '</table><table><tr><th></th><th>Nick</th><th>Joins</th><th>Quits</th><th>Parts</th><th>Kicked</th><th>Kicker</th><th>Modes</th></tr>'

    nick_list.each do |nick|
      html << '<tr><td class="color" style="background-color: #%s;"></td>' % @stats[nick].color
      html << '<td><a href="#%s">%s</a></td>' % [nick, nick]
      html << '<td>%d</td><td>%d</td><td>%d</td>' % [@stats[nick].joins, @stats[nick].quits, @stats[nick].parts]
      html << '<td>%d</td><td>%d</td><td>%s</td></tr>' % [@stats[nick].kicked, @stats[nick].kicker, @stats[nick].modes]
    end


    html << '</table><hr>'

    html << '<table><tr><th>Word</th><th>Uses</th></tr>'

    long_words.each do |w, u|
      html << '<tr><td>%s</td><td>%d</td></tr>' % [w, u]
    end

    html << '</table><hr>'
    

    html << '<h2>All Messages</h2><p><img src="%s.png" alt="%s on %s"></p><hr>' % [URI.encode(@channel), @channel, @network]


    # rrdtool shits a brick (rather than a graph) when we feed it too much, 
    # so write it to a file and pipe it in
    
    temp = "%s/%s" % [@tmp_dir, "temp"]

    File.open(temp, 'w') {|f| f.write("graph '#{my_output_dir}/#{@channel}.png' -a PNG -s #{@start_time} -e N -g #{defs} #{areas} --title='#{@channel} on #{@network}' --vertical-label='Messages Per Day' -w 800 -h 300")}

    `cat #{temp} | rrdtool -`

    File.delete temp
 
    nick_list.each_with_index do |nick, index|
      html << '<h2><a name="%s"></a>%s</h2><p>' % [nick, nick]
      html << '<img src="%s.png" alt="%s on %s"></p>' % [nick, nick, @channel]

      current = @stats[nick]

      `rrdtool graph '#{my_output_dir}/#{nick}.png' -a PNG \
      -s #{@start_time} -e N #{current.rrd_def} \
      'COMMENT:                            Average   Minimum   Maximum    Current\\c' \
      #{current.rrd_area} #{current.rrd_print} \
      --title="#{nick} on #{@channel} on #{@network}" --vertical-label="Messages Per Day" \
      -w 800 -h 300`

      write_progress_bar "Writing Output", index.to_f / nick_list.length.to_f
    end

    html << '<p>Generated by Kabaka on %s</p></div>' % Time.at(@now)
    html << '<div id="footer">
    <p><a href="http://validator.w3.org/check?uri=referer"><img src="http://www.w3.org/Icons/valid-html401" style="display: inline;" alt="Valid HTML 4.01 Strict"></a> <a href="http://jigsaw.w3.org/css-validator/check/referer"><img src="http://jigsaw.w3.org/css-validator/images/vcss" style="display: inline;" alt="Valid CSS!"></a></p></div></body></html>'

    html.close

    write_progress_bar "Writing Output", 1
    puts
  end

  class IRCUser
    attr_reader :nick, :line_count, :word_count, :color, :rrd_def, :rrd_area, :rrd_print
    attr_accessor :joins, :parts, :quits, :kicked, :kicker, :modes

    def initialize(nick, tmp_dir)
      @nick = nick

      @joins, @parts, @quits, @kicked, @kicker, @modes = 0, 0, 0, 0, 0, 0

      @line_count, @line_length = 0, 0
      @word_count = 0
      @rrd_def, @rrd_area, @rrd_print = rrd_def, rrd_area, rrd_print

      @color = Digest::MD5.hexdigest(nick)[0..5]
      if @color =~ /f.f.f./
        @color[0] = "0"
      end

      @rrd_def   = "'DEF:#{nick}=#{tmp_dir}/#{nick}.rrd:messages:AVERAGE'"
      @rrd_area  = "'AREA:#{nick}##{@color}:#{nick.ljust(20)}:STACK'"
      @rrd_print = "'GPRINT:#{nick}:AVERAGE:%4.0lf' \
                    'GPRINT:#{nick}:MIN:%8.0lf' \
                    'GPRINT:#{nick}:MAX:%8.0lf' \
                    'GPRINT:#{nick}:LAST:%8.0lf\\c' "
    end

    def add_line(line)
      @line_count  += 1
      @line_length += line.length

      @word_count +=  line.split.length
    end

    def average_line_length
      @line_length / @line_count
    end

    def words_per_line
      @word_count / @line_count
    end

  end

end # module IRCStats

