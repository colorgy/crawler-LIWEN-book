require 'crawler_rocks'
require 'pry'
require 'json'
require 'iconv'
require 'book_toolkit'

require 'thread'
require 'thwait'

class LiwenBookCrawler
  include CrawlerRocks::DSL

  def initialize update_progress: nil, after_each: nil
    @update_progress_proc = update_progress
    @after_each_proc = after_each

    @query_url = "http://www.liwen.com.tw/product.php"
  end

  def books
    @books = {}
    @threads = []

    visit "#{@query_url}?a=1"

    category_urls = @doc.xpath('//ul[@class="promenu"]/li/@onclick').map{|href| URI.join(@query_url, href.to_s.match(/(?<=href=')(.+)'/)[1].to_s).to_s}

    category_urls.each_with_index do |category_url, category_index|
      begin
        r = RestClient.get category_url
      rescue Exception => e
        sleep 3
        redo
      end
      doc = Nokogiri::HTML(r)

      page_num = doc.xpath('//a/@href').map{|href| href.to_s.match(/(?<=page=)\d+/).to_s.to_i }.max

      # 第一頁
      parse_page(doc)

      # 第二頁到最後一頁
      (2..page_num).map{|pn| "#{category_url}&page=#{pn}" }.each do |page_url|
        r = RestClient.get page_url
        doc = Nokogiri::HTML(r)

        parse_page(doc)
      end

      print "#{category_index+1} / #{category_urls.count}\n"
    end # end each category
    ThreadsWait.all_waits(*@threads)

    @books.values
  end

  def parse_page doc
    book_infos = doc.css('.list_proInfo')
    book_pics = doc.css('.list_proPic')

    doc.css('.list_proInfo').count.times do |i|
      external_image_url = URI.join(@query_url, book_pics[i].xpath('a/img/@src').to_s ).to_s
      url = URI.join(@query_url, book_pics[i].xpath('a/@href').to_s).to_s
      id = url.match(/(?<=item=)\d+/).to_s
      name = book_infos[i].css('.list_proName a').text

      author_publisher_text = book_infos[i].xpath('text()').map{|txt| txt.text.strip}.find{|x| x.include?('／') }

      author = author_publisher_text.rpartition(' ／ ')[0]
      publisher = author_publisher_text.rpartition(' ／ ')[-1]

      original_price = book_infos[i].css('.list_price').text.gsub(/[^\d]/, '').to_i

      @books[id] = {
        name: name,
        author: author,
        publisher: publisher,
        url: url,
        id: id,
        external_image_url: external_image_url,
        original_price: original_price,
        known_supplier: 'liwen'
      }
      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 30)
      )
      @threads << Thread.new do
        r = RestClient.get url
        doc = Nokogiri::HTML(r)

        detail_infos = doc.css('.detail_proInfo div')
        attr_hash = Hash[(1...detail_infos.count-1).step(2).map{|i|
          [detail_infos[i].text, detail_infos[i+1].text]
        }]

        # 只需要這兩個
        {"ISBN" => :isbn, "書號" => :internal_code}.each{|k, v| @books[id][v] = attr_hash[k] }
        begin
          @books[id][:isbn] = BookToolkit.to_isbn13(@books[id][:isbn].tr('-', '')) if @books[id][:isbn]
        rescue Exception => e
        end

        @after_each_proc.call(book: @books[id]) if @after_each_proc
        # print "|"
      end # end new Thread
    end # end each book per page
  end

end

# cc = LiwenBookCrawler.new
# File.write('liwen_books.json', JSON.pretty_generate(cc.books))
