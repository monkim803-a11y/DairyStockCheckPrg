#①https://www.jpx.co.jp/markets/statistics-equities/misc/01.html
#　から東証上場銘柄を取得する。
#②手順①で取得した銘柄について「https://finance.yahoo.co.jp/quote/[銘柄コード].T」で検索する。
#③手順②で取得した
require 'csv'
require 'uri'
require 'open-uri'
require 'json'
require 'nokogiri'

INPUT_FILE  = "prime_list.csv"
OUTPUT_FILE = "stocks.csv"

# 検索する銘柄キーワード（1301 の関連ワードを適宜足してください）
QUERY = "株価 "

# Googleニュース RSS（日本語・日本向け）
GOOGLE_NEWS_RSS = "https://news.google.com/rss/search?q=%s&hl=ja&gl=JP&ceid=JP:ja"

# 超ざっくり日本語ポジ・ネガワード辞書（必要に応じて増やす）
POSITIVE_WORDS = %w[
  好調 最高 増益 増配 上昇 高騰 買い 強気 追い風 成長 拡大 改善 好転 好材料
  回復 プラス 黒字 好決算 好評価 ポジティブ 高評価
].freeze

NEGATIVE_WORDS = %w[
  不調 悪化 減益 減配 下落 暴落 売り 弱気 逆風 縮小 悪化 悪材料
  赤字 マイナス 減速 低迷 不振 ネガティブ 下方修正 警戒 懸念 下降
].freeze  

########################################
# シンプルな感情スコア計算
########################################
# text 中のポジティブ/ネガティブ単語の出現数から
#   score_raw = (pos_count - neg_count) / (pos_count + neg_count)
# として -1〜+1 の値を作り、
#   score = (score_raw + 1) / 2 * 100
# で 0〜100 に正規化しています（小数点以下四捨五入）。
########################################

def sentiment_score(text)
  return 50 if text.nil? || text.strip.empty?

  # 全角・半角や大文字小文字を気にしないために一旦 downcase だけ
  normalized = text.downcase

  pos_count = POSITIVE_WORDS.sum { |w| normalized.scan(w).size }
  neg_count = NEGATIVE_WORDS.sum { |w| normalized.scan(w).size }

  total = pos_count + neg_count

  # ポジ/ネガワードが一切見つからないときは中立（50点）
  return 50 if total == 0

  raw = (pos_count - neg_count).to_f / total # -1.0〜+1.0
  score = ((raw + 1.0) / 2.0) * 100.0       # 0〜100 に変換
  # score.round.clamp(0, 100)
end

########################################
# ニュース取得
########################################

def fetch_news(query)
  url = format(GOOGLE_NEWS_RSS, URI.encode_www_form_component(query))
  xml = URI.open(url, "User-Agent" => "Ruby Sentiment Script").read
  doc = Nokogiri::XML(xml)

  items = doc.xpath("//item").map do |item|
    title = item.at_xpath("title")&.text.to_s
    link  = item.at_xpath("link")&.text.to_s
    desc  = item.at_xpath("description")&.text.to_s
    date  = item.at_xpath("pubDate")&.text.to_s

    text_for_sentiment = "#{title} #{desc}"
    score = sentiment_score(text_for_sentiment)

    {
      title:  title,
      link:   link,
      date:   date,
      score:  score,
      query:  query
    }
  end

  items
end

#株価情報_フェッチ
def fetch_price(code)
#   url = "https://query1.finance.yahoo.com/v7/finance/quote?symbols=#{code}.T"
  url = "https://finance.yahoo.co.jp/quote/#{code}.T"
  html = URI.open(url).read
  doc  = Nokogiri::HTML.parse(html)

  # script タグの中から window.__PRELOADED_STATE__ を含むものを探す
  script = doc.css("script").find { |s| s.text.include?("window.__PRELOADED_STATE__") }

  if script
    # JS の変数部分だけを正規表現で抜き出す
    json_text = script.text.match(/window\.__PRELOADED_STATE__\s*=\s*(\{.*\});?/m)[1]
    # JSON としてパース
    data = JSON.parse(json_text)
  else
    puts "PRELOADED_STATE が見つかりませんでした"
  end

  # quote = data.dig("quoteResponse", "result")&.first
  quote = data
  news_items = fetch_news(QUERY + quote["mainStocksPriceBoard"]["priceBoard"]["name"] + code.to_s)
  # JSONで出力（必要ならここを CSV や整形テキストに変更）
  newss = JSON.parse(JSON.pretty_generate(news_items))
  avg = (newss.map { |item| item["score"].to_f }.sum / newss.size.to_f).round(1)

  return nil unless quote
  {
    #銘柄コード
    code: code,
    #名前
    name: quote["mainStocksPriceBoard"]["priceBoard"]["name"],
    #価格
    price: quote["mainStocksPriceBoard"]["priceBoard"]["price"],
    #前日比
    change: quote["mainStocksPriceBoard"]["priceBoard"]["priceChange"],
    #前日比（%）
    change_percent: quote["mainStocksPriceBoard"]["priceBoard"]["priceChangeRate"],
    #更新時刻
    updated: quote["mainStocksPriceBoard"]["priceBoard"]["priceDateTime"],
    #出来高
    volume: quote["mainStocksDetail"]["detail"]["volume"],
    #PER
    per: quote["mainStocksDetail"]["referenceIndex"]["per"],
    #PBR
    pbr: quote["mainStocksDetail"]["referenceIndex"]["pbr"],
    #EPS
    eps: quote["mainStocksDetail"]["referenceIndex"]["eps"],
    #BPS
    bps: quote["mainStocksDetail"]["referenceIndex"]["bps"],
    #ROE
    roe: quote["mainStocksDetail"]["referenceIndex"]["roe"],
    #日次取引データ
    daily_trans_data: quote["mainItemDetailChartSetting"]["timeSeriesData"]["histories"],
    #ニュース_ポジティブスコア
    news_positive_score: avg
  }
end


########################################
# 実行部
########################################

if __FILE__ == $PROGRAM_NAME
  results = []

  # CSV.foreach(INPUT_FILE, headers: true) do |row|
  CSV.foreach(INPUT_FILE, headers: true) do |row|
    code = row["コード"]
    # if ["プライム（内国株式）","スタンダード（内国株式）","グロース（内国株式）"].include?(row["市場・商品区分"])
    if ["プライム（内国株式）"].include?(row["市場・商品区分"])
      puts "Fetching #{code}..."
      info = fetch_price(code)

      results << info if info
      sleep 0.3  # Yahoo の負荷対策
    end
  end

  CSV.open(OUTPUT_FILE, "w", encoding: 'SJIS') do |csv|
    csv << ["コード", "銘柄名", "株価", "前日比", "前日比(%)", "更新時刻","出来高","PER","PBR","EPS","BPS","ROE","#ニュース_ポジティブスコア","偏差値"]
    scores = results.map { |r| r[:news_positive_score].to_f }
    # 平均
    mean = scores.sum / scores.size

    # 標準偏差
    variance = scores.map { |s| (s - mean) ** 2 }.sum / scores.size
    stddev = Math.sqrt(variance)

    results.each do |r|
      puts r [:code]
      puts r [:name]
      puts r [:price]
      puts r [:change]
      puts r [:change_percent]
      puts r [:updated]
      puts r [:volume]
      puts r [:per]
      puts r [:pbr]
      puts r [:eps]
      puts r [:bps]
      puts r [:roe]
      puts r [:news_positive_score]
      csv << [
        r[:code],
        r[:name],
        r[:price],
        r[:change],
        r[:change_percent],
        r[:updated],
        r[:volume],
        r [:per],
        r [:pbr],
        r [:eps],
        r [:bps],
        r [:roe],
        r[:news_positive_score],
        50 + (r[:news_positive_score] - mean) / stddev * 10
      ]
    end
  end

  puts "完了！ #{OUTPUT_FILE} に保存しました。"

end