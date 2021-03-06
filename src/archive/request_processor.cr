require "./context"

class HTTP::Server::RequestProcessor
  def initialize(&@handler : HTTP::Handler::HandlerProc)
    @wants_close = false
  end

  def initialize(@handler : HTTP::Handler | HTTP::Handler::HandlerProc)
    @wants_close = false
  end

  def close
    @wants_close = true
  end

  def process(input, output, error = STDERR)
    must_close = true
    response = Response.new(output)

    begin
      until @wants_close
        request = HTTP::Request.from_io(input)

        # EOF
        break unless request

        if request.is_a?(HTTP::Request::BadRequest)
          response.respond_with_error("Bad Request", 400)
          response.close
          return
        end

        case input # || input.is_a?(OpenSSL::SSL::Socket)
        when TCPSocket
          remote_address = input.remote_address
        when OpenSSL::SSL::Socket
          io = input.io

          case io
          when TCPSocket
            remote_address = io.remote_address
          end
        end

        # TODO: Clean up default for remote_address
        remote_address ||= Socket::IPAddress.new("127.0.0.1", 3000)

        response.version = request.version
        response.reset
        response.headers["Connection"] = "keep-alive" if request.keep_alive?
        context = NewContext.new(request, response, remote_address)

        begin
          @handler.call(context)
        rescue ex
          response.respond_with_error
          response.close
          error.puts "Unhandled exception on HTTP::Handler"
          ex.inspect_with_backtrace(error)
          return
        end

        if response.upgraded?
          must_close = false
          return
        end

        response.output.close
        output.flush

        break unless request.keep_alive?

        # Skip request body in case the handler
        # didn't read it all, for the next request
        request.body.try &.close
      end
    rescue ex : Errno
      # IO-related error, nothing to do
    ensure
      begin
        input.close if must_close
      rescue ex : Errno
        # IO-related error, nothing to do
      end
    end
  end
end
