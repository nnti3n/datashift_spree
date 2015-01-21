# Copyright:: (c) Autotelik Media Ltd 2015
# Author ::   Tom Statter
# Date ::     Aug 2015
# License::   MIT
#
# Details::   Supports migrating Shopify spreadsheets to Spree
#               Currently covers :
#                 Orders
#
require 'spree_base_loader'
require 'spree_ecom'

module DataShift

  module SpreeEcom

    class ShopifyOrderLoader < SpreeBaseLoader

      # Options
      #  
      #  :reload           : Force load of the method dictionary for object_class even if already loaded
      #  :verbose          : Verbose logging and to STDOUT
      #
      def initialize(klass, options = {})
        # We want the delegated methods so always include instance methods
        opts = {:instance_methods => true}.merge( options )

        super( klass, nil, opts)

        raise "Failed to create a #{klass.name} for loading" unless load_object
      end

      # OVER RIDES

      # Options:
      #   [:dummy]           : Perform a dummy run - attempt to load everything but then roll back
      #
      def perform_load( file_name, opts = {} )
        logger.info "Shopify perform_load for Orders from File [#{file_name}]"
        super(file_name, opts)
      end

      def perform_excel_load( file_name, options = {} )

        start_excel(file_name, options)

        begin
          puts "Dummy Run - Changes will be rolled back" if options[:dummy]

          load_object_class.transaction do

            Spree::Config[:track_inventory_levels] = false

            @sheet.each_with_index do |row, i|

              @current_row_idx = i
              @current_row = row

              next if(i == header_row_index)

              # Excel num_rows seems to return all 'visible' rows, which appears to be greater than the actual data rows
              # (TODO - write spec to process .xls with a huge number of rows)
              #
              # This is rubbish but currently manually detect when actual data ends, this isn't very smart but
              # got no better idea than ending once we hit the first completely empty row
              break if(row.nil? || row.compact.empty?)

              logger.info "Processing Row #{i} : #{row}"

              # The spreadsheet contains some lines that don't forget to reset the object or we'll update rather than create
              if(load_object.id && (row[2].nil? || row[2].empty?))   # Financial Status empty on LI rows

                begin
                  process_line_item( row, load_object )
                rescue => e
                  puts e.inspect
                  logger.error(e.inspect)
                  logger.warn("Failed to add LineItems for Order ID #{load_object.id} for Row #{row}")
                end

                next  # row contains NO OTHER data

              else
                new_load_object   # main Order row, create new Spree::Order
              end

              @contains_data = false

              begin
                process_excel_row( row )

                begin
                  logger.info("Order - Assigning User with email [#{row[1]}]")

                  load_object.user = Spree.user_class.where( :email =>  @current_row[1] ).first

                  # make sure we also process the main Order rows, LineItem
                  process_line_item( row, load_object )

                rescue => e
                  logger.warn("Could not assign User #{row[1]} to Order #{load_object.number}")
                end

                # This is rubbish but currently have to manually detect when actual data ends,
                # no other way to detect when we hit the first completely empty row
                break unless(contains_data == true)

              rescue => e
                process_excel_failure(e)

                # don't forget to reset the load object
                new_load_object
                next
              end

              break unless(contains_data == true)

              # currently here as we can only identify the end of a spreadsheet by first empty row
              @reporter.processed_object_count += 1

              # TODO - make optional -  all or nothing or carry on and dump out the exception list at end
              save_and_report
            end   # all rows processed

            if(options[:dummy])
              puts "Excel loading stage complete - Dummy run so Rolling Back."
              raise ActiveRecord::Rollback # Don't actually create/upload to DB if we are doing dummy run
            end

          end   # TRANSACTION N.B ActiveRecord::Rollback does not propagate outside of the containing transaction block

        rescue => e
          puts "ERROR: Excel loading failed : #{e.inspect}"
          raise e
        ensure
          report
        end
      end

      def process_line_item( row, order )
        # for now just hard coding the columns 16 (quantity) and 17 (variant name), 20 (variant sku)
        @quantity_header_idx ||= 16
        @price_header_idx ||= 18
        @sku_header_idx ||= 20

        # if by name ...
        # by name - product = Spree::Product.where(:name => row[17]).first
        # variant = product.master if(product)

        sku = row[@sku_header_idx]

        variant = Spree::Variant.where(:sku => sku).first

        unless(variant)
          raise RecordNotFound.new("Unable to find Product with sku [#{sku}]")
        end

        logger.info("Process LineItem - Found Variant [#{variant.sku}] (#{variant.name}") if(variant)

        sku = row[@sku_header_idx]
        quantity = row[@quantity_header_idx].to_i
        price = row[@price_header_idx].to_f

        if(quantity > 0)

          logger.info("Adding LineItem for #{sku} with Quantity #{quantity} to Order #{load_object.inspect}")

          # idea incase we need full stock management
          # variant.stock_items.first.adjust_count_on_hand(quantity)

          line_item = Spree::LineItem.new(:variant => variant,
                                          :quantity => quantity,
                                          :price => row[@price_header_idx],
                                          :order => order,
                                          :currency => order.currency)

          unless(line_item.valid?)
            logger.error("Invalid LineItem :  #{line_item.errors.messages.inspect}")
            logger.error("Failed - Unable to add LineItems to Order #{order.number} (#{order.id})")
          else
            line_item.save
            logger.info("Success - Added LineItems to Order #{order.number}")
          end
        end
      end

    end

  end
end