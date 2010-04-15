# TODO
#  switch to xauth
#    ask for u/p once, then save token (https://gist.github.com/304123/17685f51b5ecad341de9b58fb6113b4346a7e39f)

$KCODE = 'u'

%w[rubygems pp net/http json twitter-text term/ansicolor twitter highline/import getoptlong].each{|l| require l}

include Term::ANSIColor

class Termonate

  def initialize(user, pass, client)
    httpauth = Twitter::HTTPAuth.new(user, pass)
    @client = Twitter::Base.new(httpauth)
    @friends = []
    @client = client
    @resonance = {}
    @screen_name = user
    @processed = 0
  end

  def highlight(text)
    text.gsub(Twitter::Regex::REGEXEN[:extract_mentions], ' ' + cyan('@\2')).
      gsub(Twitter::Regex::REGEXEN[:auto_link_hashtags], ' ' + yellow('#\3'))
  end

  def tweet_text(sn, text)
    if sn && text
      red(bold(sn)) + ': ' + highlight(text) + "\n"
    else
      "undefined (yet)...\n"
    end
  end

  def print_resonance
    # clear screen
    print "\033[2 J\033[1H"
    puts "resonance...\n"
    inverted = {}
    @resonance.each do |k,v|
      if v.length > 1
        count = v[0]
        inverted[v[0]] ||= []
        inverted[v[0]] << v
      end
    end
    sorted = inverted.keys.sort.reverse
    sorted.each do |e|
      inverted[e].each do |v|
        puts "\t#{v[0]}: #{tweet_text(v[1],v[2])}"
      end
    end
  end

  def resonate(data, &block)
    k = data['target_object']['id']
    unless @resonance[k]
      @resonance[k] = [0]
      Thread.new do
        begin
          status = @client.status(k)
          @resonance[k] << status.user.screen_name
          @resonance[k] << status.text
          print_resonance
        rescue
          puts "oopsies fetching #{k}\n: #{$!}\n#{$!.backtrace}"
        end
      end
    end
    @resonance[k][0] = yield @resonance[k][0]
    @processed += 1
    if @processed % 1 == 0
      print_resonance
    end
  end

  def process(data)
    if data['event']
      case data['event']
      when 'favorite'
        resonate(data) {|r| r + 1}
      when 'unfavorite'
        resonate(data) {|r| r - 1}
      when 'retweet'
        resonate(data) {|r| r + 1}
      end
    end
  rescue Twitter::RateLimitExceeded
    puts "event dropped due to twitter rate limit (reset in #{@client.rate_limit_status['reset_time_in_seconds'] - Time.now} seconds)"
    p @client.rate_limit_status
  end
end

class Hose
  KEEP_ALIVE  = /\A3[\r][\n][\n][\r][\n]/
  DECHUNKER   = /\A[0-F]+[\r][\n]/
  NEWLINE     = /[\n]/
  CRLF        = /[\r][\n]/
  EOF         = /[\r][\n]\Z/

  def unchunk(data)
    data.gsub(/\A[0-F]+[\r][\n]/, '')
  end

  def keep_alive?(data)
    data =~ KEEP_ALIVE
  end

  def extract_json(lines)
    # lines.map {|line| Yajl::Stream.parse(StringIO.new(line)).to_mash rescue nil }.compact
    lines.map {|line| JSON.parse(line).to_hash rescue nil }.compact
  end

  # filter determines whether you remove @replies from users you don't follow
  def run(user, pass, host, path, debug=false, filter=false)
    if debug
      $stdin.each_line do |line|
        process(line)
      end
    else
      begin
        Net::HTTP.start(host) {|http|
          req = Net::HTTP::Get.new(path)
          req.basic_auth user, pass
          http.request(req) do |response|
            buffer = ''
            raise response.inspect unless response.code == '200'
            response.read_body do |data|
              unless keep_alive?(data)
                buffer << unchunk(data)

                if buffer =~ EOF
                  lines = buffer.split(CRLF)
                  buffer = ''
                else
                  lines = buffer.split(CRLF)
                  buffer = lines.pop
                end

                extract_json(lines).each {|line| yield(line)}
              end
            end
          end
        }
      rescue Errno::ECONNRESET, EOFError
        puts "disconnected from streaming api, reconnecting..."
        sleep 5
        retry
      end
    end
  end
end

user = ask("Enter your username:  ")
pass = ask("Enter your password:  ") { |q| q.echo = '*' }

def usage
  puts "usage: earlybird.rb [-d] [-l list] [-u url] [-h host]"
  puts "options: "
  puts "  -d debug mode, read json from stdin"
  puts "  -u userstream path. Default: /2b/user.json"
  puts "  -h userstream hostname: Default: chirpstream.twitter.com"
end

opts = GetoptLong.new(
      [ '--help', GetoptLong::NO_ARGUMENT ],
      [ '-d', GetoptLong::REQUIRED_ARGUMENT ],
      [ '-u', GetoptLong::OPTIONAL_ARGUMENT],
      [ '-h', GetoptLong::OPTIONAL_ARGUMENT]
    )

$debug = false
$url = '/2b/user.json'
$host = 'chirpstream.twitter.com'
opts.each do |opt, arg|
  case opt
  when '--help'
    usage
    exit 0
  when '-d'
    $debug = true
  when '-u'
    $url = arg
  when '-h'
    $host = arg
  end
end

# fetch users

auth = Twitter::HTTPAuth.new(user, pass)
$client = Twitter::Base.new(auth)

puts "connecting to http://#{$host}#{$url}"

t = Termonate.new(user, pass, $client)
t.print_resonance
Hose.new.run(user, pass, $host, $url, $debug){|line| t.process(line)}
