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
    @current_date, @start_time, @last_time = "", 0, 0
    @tmp_dir = `mktemp -d`.chomp

    @total_lines = 0

    @slaps = [
      "slaps",
      "hits",
      "punches",
      "attacks",
      "stabs",
      "shoots"
    ]

    @hourly, @weekly = [], []

    @options = options

    @stats, @long_words, @emoticons, @domains = {}, {}, {}, {}

    @network, @channel = File.basename(filename).split(/\./)[1..2]

    read_file filename
    write_html

    clean
  end



  def self.clean
    `rm -r #{@tmp_dir}` if Dir.exists? @tmp_dir
  end



  def self.word_stats(nick, action, arr, line)
    arr.shift if action
    return if arr.empty?

    arr.each do |word|
      if word =~ /\Ahttps?:\/\/(www\.)?([^\/]+)/
        @stats[nick].urls += 1

        domain = $2.downcase

        @domains[domain] ||= 0
        @domains[domain]  += 1
      end

      # TODO: Make this more complete.
      if word =~ /\A(:(',)?-?.|.-?:|;.;|-.-|\.[^.]{1}\.)\Z/
        @stats[nick].emoticons += 1

        @emoticons[word] ||= 0
        @emoticons[word]  += 1
      end

      if word =~ /\As\/.+\/.*\/.*\Z/
        @stats[nick].regex += 1
      end

      next if word.length < @options[:top_word_length]
      next if word =~ /\A[[:punct:]]/ or word =~ /[[:punct:]]\Z/
      
      word.downcase!

      @long_words[word] ||= 0
      @long_words[word]  += 1
    end

    @stats[nick].periods      += line.count '.'
    @stats[nick].commas       += line.count ','
    @stats[nick].questions    += line.count '?'
    @stats[nick].exclamations += line.count '!'

    @stats[nick].attacks += 1 if action and @slaps.include? arr.first.downcase

    if line =~ /[A-Z]{3,}/ and line == line.upcase
      @stats[nick].allcaps += 1
    end
  end



  def self.parse_line(file, size, line)
    unless line =~ /\A(\d{4})-(\d{2})-(\d{2})\s(\d{2}):(\d{2}):(\d{2})\t[@+&~!%]?([^\t]+)\t(.+)\Z/
      return
    end

    @total_lines += 1

    year, month, day = $1, $2, $3
    hour, minute, second = $4.to_i, $5.to_i, $6.to_i
    nick, text = $7, $8
    date = "%s%s%s" % [year, month, day]
    text_arr = text.split
    action = nick == " *"

    nick = text_arr.first if action

    return if nick.include? ' ' or nick == "=!="

    time = Time.mktime(year, month, day)
    ts = time.to_i
    wday = time.wday
    @last_time = Time.mktime(year, month, day, hour, minute, second)

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
       DS:messages:GAUGE:86400:0:100000 \
       RRA:AVERAGE:0.5:1:1825 \
       RRA:MAX:0.5:1:1825`

       @stats[nick] ||= IRCUser.new(nick, @tmp_dir)
    end

    @hourly[hour] ||= 1
    @hourly[hour]  += 1

    @weekly[wday] ||= 1
    @weekly[wday]  += 1

    @nick_stats[nick] ||= 0
    @nick_stats[nick]  += 1

    word_stats nick, action, text_arr, text
    @stats[nick].add_line(text)
    @stats[nick].actions += 1 if action
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
        if File.fnmatch(check.str, nick)
          if check.nick == "*"
            return "ANONYMOUS"
          else
            return check.nick
          end
        end
      else
        if nick == check.str
          if check.nick == "*"
            return "ANONYMOUS"
          else
            return check.nick
          end
        end
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

    domains    = @domains.sort_by    {|d, c| c * -1}.shift(@options[:top_domain_count])
    emoticons  = @emoticons.sort_by  {|e, c| c * -1}.shift(@options[:top_emoticon_count])
    long_words = @long_words.sort_by {|w, c| c * -1}.shift(@options[:top_word_count])

    mt = @options[:message_threshold]
    num_deleted = @stats.length - @stats.delete_if {|n, u| u.line_count < mt}.length


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
td.highest {
  font-weight: bold;
}
#content p {
  text-align: justify;
}
#content p.center {
  text-align: center;
}
#footer {
  width: 800px;
  text-align: center;
  margin: 5px auto;
}
</style></head><body><div id=\"content\"><h1>Channel Activity - #{@channel} on #{@network}</h1>
<p>Nicks are changed to lower case, some characters are replaced with underscores, and
some manual nick change correction is performed. Only users that have spoken at least
#{mt} lines are shown. #{num_deleted.to_fs} users did not make the cut.</p>
<p>#{@total_lines.to_fs} total lines were parsed for #{Time.at(@start_time)} to #{@last_time}.</p>"
    

    # Hourly graph

    html << '<hr><h2>Activity by Hour</h2><p class="center"><em>Time Zone: UTC%s</em></p>' % Time.now.strftime("%z")

    hourly_start = Time.mktime(2000, 1, 1, 0, 0, 0).to_i

    `rrdtool create '#{@tmp_dir}/.hourly.rrd' --step 3600 \
    --start #{hourly_start} \
    DS:messages:GAUGE:3600:0:100000 \
    RRA:MAX:0.5:1:365`
    
    hourly = hourly_start

    @hourly.each do |m|
      hourly += 3600
      `rrdtool update '#{@tmp_dir}/.hourly.rrd' '#{hourly}:#{m}'`
    end

    `rrdtool graph \
    '#{my_output_dir}/hourly-#{@channel}.png' \
    -a PNG -s #{hourly_start} -e #{hourly_start + 86400} -g -M -l 0 \
    --vertical-label='Messages Per Hour' \
     --x-grid HOUR:1:HOUR:1:HOUR:1:0:%H \
    'DEF:messages=#{@tmp_dir}/.hourly.rrd:messages:MAX' \
    'AREA:messages#00FF00:Total Messages' \
    -w 800 -h 300`

    html << '<p><img src="hourly-%s.png" alt="Usage by hour"></p>' % URI.encode(@channel)


    # Weekly graph

    html << '<hr><h2>Activity by Day of Week</h2><p class="center">'

    weekly_start = Time.mktime(2000, 1, 2, 0, 0, 0).to_i

    `rrdtool create '#{@tmp_dir}/.weekly.rrd' --step 86400 \
    --start #{weekly_start} \
    DS:messages:GAUGE:86400:0:100000 \
    RRA:MAX:0.5:1:365`
    
    weekly = weekly_start

    @weekly.each do |m|
      weekly += 86400
      `rrdtool update '#{@tmp_dir}/.weekly.rrd' '#{weekly}:#{m}'`
    end

    `rrdtool graph \
    '#{my_output_dir}/weekly-#{@channel}.png' \
    -a PNG -s #{weekly_start} -e #{weekly_start + (86400 * 7)} -g -M -l 0 \
    --vertical-label='Messages Per Day' \
     --x-grid DAY:1:DAY:1:DAY:1:0:%A \
    'DEF:messages=#{@tmp_dir}/.weekly.rrd:messages:MAX' \
    'AREA:messages#00FF00:Total Messages' \
    -w 800 -h 300`

    areas, defs, = "", ""

    nick_list.each do |nick|
      areas << "%s " % @stats[nick].rrd_area
      defs  << "%s " % @stats[nick].rrd_def
    end

    html << '<p><img src="weekly-%s.png" alt="Usage by day of week"></p>' % URI.encode(@channel)


    # General stats tables

    html << "<hr><h2>General Statistics</h2>"

    print_table(html, nick_list,
                :line_count           => "Total Lines",
                :average_line_length  => "Average Line Length",
                :words_per_line       => "Words Per Line" )

    print_table(html, nick_list,
                :joins        => "Joins",
                :quits        => "Quits",
                :parts        => "Parts",
                :kicked       => "Kicked",
                :kicker       => "Kicker",
                :modes        => "Modes")
    
    print_table(html, nick_list,
                :emoticons    => "Emoticons",
                :attacks      => "Slaps",
                :urls         => "URLs",
                :regex        => "Regexes",
                :actions      => "Actions")

    print_table(html, nick_list,
                :allcaps      => "All-Caps",
                :periods      => "Periods",
                :commas       => "Commas",
                :questions    => "Question Marks",
                :exclamations => "Exclamation Marks")

    # Top words table

    html << '<hr><h2>Top %d Words</h2>' % @options[:top_word_count]

    if @options[:top_word_length] > 1
      html << '<p class="center"><em>Only words %d characters or longer are counted.</em></p>' % @options[:top_word_length]
    end

    html << '<table><tr><th></th><th>Word</th><th>Uses</th></tr>'
    long_words.each_with_index {|(w, u), i| html << '<tr><td>%d</td><td>%s</td><td>%s</td></tr>' % [i+1, w, u.to_fs]}
    html << '</table>'


    # Top emoticons table

    html << '<hr><h2>Top %d Emoticons</h2>' % @options[:top_emoticon_count]
    html << '<table><tr><th></th><th>Emoticon</th><th>Uses</th></tr>'
    emoticons.each_with_index {|(e, u), i| html << '<tr><td>%d</td><td>%s</td><td>%s</td></tr>' % [i+1, e, u.to_fs]}
    html << '</table>'


    # Top domains table

    html << '<hr><h2>Top %d Domains in URLs</h2>' % @options[:top_domain_count]
    html << '<table><tr><th></th><th>Domain Name</th><th>Uses</th></tr>'
    domains.each_with_index {|(d, u), i| html << '<tr><td>%d</td><td>%s</td><td>%s</td></tr>' % [i+1, d, u.to_fs]}
    html << '</table>'


    # All messages graph

    html << '<hr><h2>All Messages</h2><p><img src="%s.png" alt="%s on %s"></p><hr>' % [URI.encode(@channel), @channel, @network]


    # rrdtool shits a brick (rather than a graph) when we feed it too much, 
    # so write it to a file and pipe it in
    
    temp = "%s/%s" % [@tmp_dir, "temp"]

    File.open(temp, 'w') {|f| f.write("graph '#{my_output_dir}/#{@channel}.png' -a PNG -s #{@start_time} -e #{@last_time.to_i} -g #{defs} #{areas} --title='#{@channel} on #{@network}' --vertical-label='Messages Per Day' -l 0 -w 800 -h 300")}

    `cat #{temp} | rrdtool -`

    File.delete temp
 

    # User messages graphs

    html << '<h2>User Message Graphs</h2>'

    nick_list.each_with_index do |nick, index|
      html << '<p><a name="%s"></a>' % [nick, nick]
      html << '<img src="%s.png" alt="%s on %s"></p>' % [nick, nick, @channel]

      current = @stats[nick]

      `rrdtool graph '#{my_output_dir}/#{nick}.png' -a PNG \
      -s #{@start_time} -e #{@last_time.to_i} #{current.rrd_def} \
      'COMMENT:                            Average   Minimum   Maximum    Current\\c' \
      #{current.rrd_area} #{current.rrd_print} \
      --title="#{nick} on #{@channel} on #{@network}" --vertical-label="Messages Per Day" \
      -w 800 -h 300`

      write_progress_bar "Writing Output", index.to_f / nick_list.length.to_f
    end

    html << '<hr><p class="center">Generated by %s@%s on %s</p></div>' % [ENV['USER'], ENV['HOSTNAME'], Time.at(@now)]
    html << '<div id="footer">
    <p><a href="http://validator.w3.org/check?uri=referer"><img src="http://www.w3.org/Icons/valid-html401" style="display: inline;" alt="Valid HTML 4.01 Strict"></a> <a href="http://jigsaw.w3.org/css-validator/check/referer"><img src="http://jigsaw.w3.org/css-validator/images/vcss" style="display: inline;" alt="Valid CSS!"></a></p></div></body></html>'

    html.close

    write_progress_bar "Writing Output", 1
    puts
  end



  def self.print_table(html, nicks_sorted, fields)
    html << '<table><tr><th></th><th>Nick</th>'
    
    winners = {}

    fields.each_pair do |field, label|
      highest = 0
      winner  = []

      @stats.each_pair do |nick, stats|
        val = stats.send(field)

        if val > highest
          winner = [nick]
          highest = val
        elsif val == highest
          winner << nick
        end
      end

      winners[field] = winner
      html << '<th>%s</th>' % label
    end

    html << '</tr>'

    nicks_sorted.each do |nick|
      html << '<tr><td class="color" style="background-color: #%s;"></td>' % @stats[nick].color
      html << '<td><a href="#%s">%s</a></td>' % [nick, nick]

      fields.each_key do |field|
        val = @stats[nick].send(field)

        c = winners[field].include?(nick) ? ' class="highest"' : ''
        
        html << '<td%s>%s</td>' % [c, val.to_fs]
      end

      html << '</tr>'
    end

    html << '</table>'
  end



  class IRCUser
    attr_reader :nick, :line_count, :word_count, :color, :rrd_def, :rrd_area, :rrd_print
    attr_accessor :joins, :parts, :quits, :kicked, :kicker, :modes, :periods, :commas, :regex
    attr_accessor :questions, :exclamations, :emoticons, :attacks, :urls, :actions, :allcaps

    def initialize(nick, tmp_dir)
      @nick = nick

      @joins, @parts, @quits, @kicked, @kicker, @modes = 0, 0, 0, 0, 0, 0
      @questions, @exclamations, @emoticons, @periods = 0, 0, 0, 0
      @commas, @attacks, @urls, @actions, @allcaps, @regex = 0, 0, 0, 0, 0, 0

      @line_count, @line_length = 0, 0
      @word_count = 0
      @rrd_def, @rrd_area, @rrd_print = rrd_def, rrd_area, rrd_print

      @color = Digest::MD5.hexdigest(nick)[0..5]
      if @color =~ /f.f.f./
        @color[0] = "0"
      end

      @rrd_def   = "'DEF:#{nick}=#{tmp_dir}/#{nick}.rrd:messages:MAX'"
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

class Numeric

  # to formatted string (number seperators!)
  def to_fs
    to_s.reverse.gsub(/...(?=.)/,'\&,').reverse
  end

end
