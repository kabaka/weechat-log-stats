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

module IRCStats

  def self.run(filename, options)
    @nick_stats, @nick_totals, @now = {}, {}, Time.now.to_i
    @current_date, @start_time = "", 0
    @defs, @areas, @print = {}, {}, {}
    @tmp_dir = `mktemp -d`.chomp

    @network, @channel = File.basename(filename).split(/\./)[1..2]

    read_file filename

    write_html options[:output_dir], options[:message_threshold]

    clean
  end

  def self.clean
    `rm -r #{@tmp_dir}` if Dir.exists? @tmp_dir
  end

  def self.parse_line(file, size, line)
    unless line =~ /\A(\d{4})-(\d{2})-(\d{2})\s[\d:]{8}\t[@+&~!%]?([^\t]+)\t([^ ]+)( |\Z)/
      return
    end

    year, month, day = $1, $2, $3
    nick, first_word = $4, $5
    date = "%s%s%s" % [year, month, day]

    return if nick.include? ' ' or nick =~ /\A<?-->?|=!=\Z/

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

       color = "%06x" % (rand * 0xffffff) # TODO: Only pick visible colors.

       @defs[nick]  = "'DEF:#{nick}=#{@tmp_dir}/#{nick}.rrd:messages:AVERAGE'"
       @areas[nick] = "'AREA:#{nick}##{color}:#{nick.ljust(20)}:STACK'"
       @print[nick] = "'GPRINT:#{nick}:AVERAGE:%4.0lf' \
                       'GPRINT:#{nick}:MIN:%8.0lf' \
                       'GPRINT:#{nick}:MAX:%8.0lf' \
                       'GPRINT:#{nick}:LAST:%8.0lf\\c' "
    end

    @nick_stats[nick] ||= 0
    @nick_stats[nick]  += 1

    @nick_totals[nick] ||= 0
    @nick_totals[nick]  += 1
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
  def self.write_html(output_dir, message_threshold)
    @nick_totals.delete_if {|n, t| t < message_threshold}

    write_progress_bar "Writing Output", 0

    my_output_dir = output_dir.clone
    Dir.mkdir my_output_dir unless Dir.exists? my_output_dir

    my_output_dir << "/%s/" % @network
    Dir.mkdir my_output_dir unless Dir.exists? my_output_dir

    my_output_dir << "%s/" % @channel

    if Dir.exists? my_output_dir
      `rm -r '#{my_output_dir}'`
    end

    Dir.mkdir my_output_dir

    nick_list = @nick_totals.keys.sort

    html = File.open("#{my_output_dir}/index.html", "w")
    html << " <!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">
<html><head><title>#{@channel} on #{@network}</title>
<style type=\"text/css\">
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
  width: 400px;
  border: 0;
  margin: 10px auto;
}
th {
  background-color: #FFF;
}
tr {
  background-color: #DEDEDE;
}
tr a {
  text-decoration: none;
}
</style></head><body><div id=\"content\"><h1>User Activity in #{@channel} on #{@network}</h1>
<p><em>Nicks are changed to lower case, some characters are replaced with underscores, and
some manual nick change correction is performed. Only users that have spoken at least
#{message_threshold} lines are shown.</em></p>
<table><tr><th>Nick</th><th>Total Lines</th></tr>"

    nick_list.each do |nick|
      html << '<tr><td><a href="#%s">%s</a></td><td>%d</td></tr>' % [nick, nick, @nick_totals[nick]]
    end

    html << '</table><hr>'
    html << '<h2>All Messages</h2><p><img src="%s.png" alt="%s on %s" /></p><hr>' % [URI.encode(@channel), @channel, @network]

    temp = "%s/%s" % [@tmp_dir, "temp"]

    File.open(temp, 'w') {|f| f.write("graph '#{my_output_dir}/#{@channel}.png' -a PNG -s #{@start_time} -e N -g #{@defs.values.join(" ")} #{@areas.values.join(" ")} --title='#{@channel} on #{@network}' --vertical-label='Messages Per Day' -w 800 -h 300")}

    `cat #{temp} | rrdtool -`

    File.delete temp
 
    nick_list.each_with_index do |nick, index|
      html << '<h2><a name="%s" />%s</h2><p><img src="%s.png" alt="%s on %s" /></p>' % [nick, nick, nick, nick, @channel]

      `rrdtool graph '#{my_output_dir}/#{nick}.png' -a PNG \
      -s #{@start_time} -e N #{@defs[nick]} \
      'COMMENT:                            Average   Minimum   Maximum    Current\\c' \
      #{@areas[nick]} #{@print[nick]} \
      --title="#{@channel} on #{@network}" --vertical-label="Messages Per Day" \
      -w 800 -h 300`

      write_progress_bar "Writing Output", index.to_f / nick_list.length.to_f
    end

    html << "<p>Generated by Kabaka on %s</p></div></body></html>" % Time.at(@now)

    html.close

    write_progress_bar "Writing Output", 1
    puts
  end

end # module IRCStats

