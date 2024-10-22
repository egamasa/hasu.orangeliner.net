require 'aws-sdk-s3'
require 'aws-sdk-ssm'
require 'json'
require 'net/http'
require 'rexml/document'
require 'time'
require 'uri'

YOUTUBE_API_ENDPOINT = 'https://www.googleapis.com/youtube/v3'
YOUTUBE_CHANNEL_ID = 'UCxUgvwrVfqVpyak4cuKcevQ'
MAX_CONTENTS_COUNT = 5

def get_youtube_api_key
  parameter_name = "/#{ENV['YOUTUBE_API_KEY_PARAMETER_NAME']}"
  client = Aws::SSM::Client.new(region: ENV['PARAMETER_REGION'])

  begin
    req = { name: parameter_name, with_decryption: true }
    res = client.get_parameter(req)
  rescue => e
    raise e
  end

  res.parameter.value
end

def get_bucket_api_token
  parameter_name = "/#{ENV['BUCKET_API_TOKEN_PARAMETER_NAME']}"
  client = Aws::SSM::Client.new(region: ENV['PARAMETER_REGION'])

  begin
    req = { name: parameter_name, with_decryption: true }
    res = client.get_parameter(req)
  rescue => e
    raise e
  end

  JSON.parse(res.parameter.value)
end

def request_youtube_api(endpoint, params)
  base_url = "#{YOUTUBE_API_ENDPOINT}/#{endpoint}"
  uri = URI(base_url)
  uri.query = URI.encode_www_form(params)
  res = Net::HTTP.get_response(uri)

  res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
end

# 動画リスト取得（キーワード検索）
def get_youtube_search_videos(channel_id, search_query = nil)
  params = {
    part: 'id',
    channelId: channel_id,
    order: 'date',
    maxResults: 10,
    type: 'video',
    key: @youtube_api_key
  }
  params[:q] = search_query if search_query

  request_youtube_api('search', params)
end

# 動画リスト取得（プレイリスト指定）
def get_youtube_playlist_videos(playlist_id)
  params = {
    part: 'contentDetails',
    playlistId: playlist_id,
    maxResults: 10,
    key: @youtube_api_key
  }

  request_youtube_api('playlistItems', params)
end

# 動画情報取得
def get_youtube_videos(video_ids)
  params = { part: 'snippet', id: video_ids.join(','), key: @youtube_api_key }

  request_youtube_api('videos', params)
end

# 動画情報抽出
def extract_videos_info(videos)
  videos_info = []

  i = 0
  videos['items'].each do |video|
    break if i >= MAX_CONTENTS_COUNT

    # 除外: 非公開動画
    next if video['snippet']['title'] == 'Private video'

    # 除外: 活動記録（外国語版）
    next if video['snippet']['title'].include?('English Subtitles')
    next if video['snippet']['title'].include?('简体字幕')
    next if video['snippet']['title'].include?('繁體字幕')

    i += 1
    videos_info << {
      title: video['snippet']['title'],
      link: "https://www.youtube.com/watch?v=#{video['id']}",
      date: video['snippet']['publishedAt'],
      thumbnail: video['snippet']['thumbnails']['default']['url'],
      upcoming: video['snippet']['liveBroadcastContent'] == 'upcoming'
    }
  end

  videos_info
end

# RSSフィード取得
def fetch_rss(url)
  xml = Net::HTTP.get(URI.parse(url))
  rss_feed = REXML::Document.new(xml)

  rss_contents = []
  rss_feed
    .elements
    .each('rss/channel/item') do |item|
      rss_contents << {
        title: item.elements['title'].text,
        link: item.elements['link'].text,
        date: item.elements['pubDate'].text,
        thumbnail: item.elements['media:thumbnail'].text.gsub(/width=\d+/, 'width=200')
      }
    end

  rss_contents
end

def save_to_bucket(bucket_name, object_key, hash_data)
  json_data = JSON.generate(hash_data)

  bukcet_api_token = get_bucket_api_token()

  s3_client =
    Aws::S3::Client.new(
      region: 'auto',
      access_key_id: bukcet_api_token['access_key_id'],
      secret_access_key: bukcet_api_token['secret_access_key'],
      endpoint: bukcet_api_token['endpoint'],
      force_path_style: true
    )

  s3_client.put_object(
    bucket: ENV['BUCKET_NAME'],
    key: 'hasu/contents.json',
    content_type: 'application/json',
    body: json_data
  )
end

def main
  @youtube_api_key = get_youtube_api_key()

  contents = { videos: {}, notes: {} }

  # YoutTube (キーワード検索)
  youtube_search_list = { all: nil, mirapaRadio: 'みらくら視聴覚室ラジオ', story: '3Dアニメ 活動記録' }

  youtube_search_list.each do |search_list_name, search_query|
    search_list_name_sym = search_list_name.to_sym
    contents[:videos][search_list_name_sym] = []

    channel_videos = get_youtube_search_videos(YOUTUBE_CHANNEL_ID, search_query)
    video_ids = channel_videos['items'].map { |video| video['id']['videoId'] } if channel_videos

    videos = get_youtube_videos(video_ids) if video_ids
    contents[:videos][search_list_name_sym] = extract_videos_info(videos) if videos
  end

  # YouTube (プレイリスト指定)
  youtube_playlists = {
    withMeets: 'PLu7E7HFun3xB33SP01_NZzJpV-TiRyx0K',
    fesLive: 'PLu7E7HFun3xBqgsTabwfrJkHc0FYE5RmI',
    seeHasu: 'PLu7E7HFun3xC0k9Jm6Z0UUf_JNRNGEfk2',
    linkNama: 'PLu7E7HFun3xA0HJsKiJVyG-9U_Lxk8BMk',
    lyricVideo: 'PLu7E7HFun3xCfBwgq2wYRNJXN9U6Q5Zyi'
  }

  youtube_playlists.each do |playlist_name, playlist_id|
    playlist_name_sym = playlist_name.to_sym
    contents[:videos][playlist_name_sym] = []

    playlist_videos = get_youtube_playlist_videos(playlist_id)
    video_ids =
      playlist_videos['items'].map { |video| video['contentDetails']['videoId'] } if playlist_videos

    videos = get_youtube_videos(video_ids) if video_ids
    contents[:videos][playlist_name_sym] = extract_videos_info(videos) if videos
  end

  # note (RSS)
  note_rss = { all: 'https://note.com/lovelive_hasu/rss' }

  note_rss.each do |rss_name, rss_url|
    rss_name_sym = rss_name.to_sym
    contents[:notes][rss_name_sym] = []

    rss_contents = fetch_rss(rss_url)

    if rss_contents
      i = 0
      rss_contents.each do |item|
        break if i >= MAX_CONTENTS_COUNT
        i += 1

        contents[:notes][rss_name_sym] << {
          title: item[:title],
          link: item[:link],
          date: Time.parse(item[:date]).utc.iso8601,
          thumbnail: item[:thumbnail]
        }
      end
    end
  end

  contents[:lastUpdate] = Time.now.utc.iso8601

  save_to_bucket(ENV['PARAMETER_REGION'], 'hasu/contents.json', contents)
end

def lambda_handler(event:, context:)
  main()
end
