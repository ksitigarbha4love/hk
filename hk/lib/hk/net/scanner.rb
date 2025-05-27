module HK
  module Net
    class Scanner
      def initialize
        # Ensure TTY::Color is available or provide a fallback
        if defined?(TTY::Color)
          @pastel = TTY::Color
        else
          # Fallback if TTY::Color is not available
          @pastel = Object.new
          def @pastel.method_missing(*args, &block); args.first; end
          def @pastel.respond_to_missing?(method_name, include_private = false); true; end
        end
        # puts @pastel.cyan("HK::Net::Scanner initialized.") # Keep quiet for now
      end

      # tcp_scan still receives a pre-parsed array of ports
      def tcp_scan(target, ports_array, options = {})
        puts @pastel.cyan("HK::Net::Scanner:") + " Starting TCP scan for " + @pastel.yellow(@pastel.bold(target))
        # Ensure ports_array is a flattened, unique, sorted list of valid integers
        sanitized_ports = Array(ports_array).flatten.uniq.sort.select { |p| p.is_a?(Integer) && p > 0 && p <= 65535 }

        puts @pastel.dim("  Targeting ports: #{sanitized_ports.inspect}")
        puts @pastel.dim("  Scan options received: #{options.inspect}") # Log received options

        if options[:rate]
          puts @pastel.dim("  Rate limit specified: #{options[:rate]} pps (simulation)")
        end
        if options[:timeout]
          puts @pastel.dim("  Timeout specified: #{options[:timeout]}s (simulation)")
        end

        open_ports = []
        closed_ports = []

        # Existing simulation logic (can be kept or fine-tuned)
        if target.is_a?(String) && target.include?("example.com")
          sanitized_ports.each do |port|
            if [80, 443, 8080, 8081].include?(port) # Added 8081 for testing ranges
              open_ports << port
            else
              closed_ports << port
            end
          end
        else
          sanitized_ports.each do |port|
            if [21, 22, 25, 80, 110, 143, 443, 3306, 3389, 5432, 8000, 8080].include?(port) || (port % 10 == 0 && port < 10000 && port > 1000)
              open_ports << port
            else
              closed_ports << port
            end
          end
          open_ports = open_ports.sample(3 + rand(3)) if open_ports.size > 5 # Ensure not too many are open for the simulation
          closed_ports = sanitized_ports - open_ports
        end
        
        puts @pastel.green("  Scan complete.") + " Open ports: " + open_ports.inspect

        {
          target: target,
          open_ports: open_ports.sort,
          closed_ports: closed_ports.sort,
          scanned_ports: sanitized_ports, # Add what was actually targeted
          options: options
        }
      end
    end
  end
end
