# $Id$

require 'logging'
require 'logging/layout'

module Logging
module Layouts

  #
  # A flexible layout configurable with pattern string.
  #
  # The goal of this class is to format a LogEvent and return the results as
  # a String. The results depend on the conversion pattern.
  #
  # The conversion pattern is closely related to the conversion pattern of
  # the sprintf function. A conversion pattern is composed of literal text
  # and format control expressions called conversion specifiers.
  #
  # You are free to insert any literal text within the conversion pattern.
  #
  # Each conversion specifier starts with a percent sign (%) and is followed
  # by optional format modifiers and a conversion character. The conversion
  # character specifies the type of data, e.g. logger, level, date, thread
  # ID. The format modifiers control such things as field width, padding,
  # left and right justification. The following is a simple example.
  #
  # Let the conversion pattern be "%-5l [%c]: %m\n" and assume that the
  # logging environment was set to use a Pattern layout. Then the statements
  #
  #    root = Logging::Logger[:root]
  #    root.debug("Message 1")
  #    root.warn("Message 2")
  #
  # would yield the output
  #
  #    DEBUG [root]: Message 1
  #    WARN  [root]: Message 2
  #
  # Note that there is no explicit separator between text and conversion
  # specifiers. The pattern parser knows when it has reached the end of a
  # conversion specifier when it reads a conversion character. In the example
  # above the conversion specifier %-5l means the level of the logging event
  # should be left justified to a width of five characters. The recognized
  # conversion characters are 
  #
  #  [c]  Used to output the name of the logger that generated the log
  #       event.
  #  [d]  Used to output the date of the log event. The format of the
  #       date is specified using the :date_pattern option when the Layout
  #       is created. ISO8601 format is assumed if not date pattern is given.
  #  [F]  Used to output the file name where the logging request was issued.
  #  [l]  Used to output the level of the log event.
  #  [L]  Used to output the line number where the logging request was
  #       issued.
  #  [m]  Used to output the application supplied message associated with
  #       the log event.
  #  [M]  Used to output the method name where the logging request was
  #       issued.
  #  [p]  Used to output the process ID of the currently running program.
  #  [r]  Used to output the number of milliseconds elapsed from the
  #       construction of the Layout until creation of the log event.
  #  [t]  Used to output the object ID of the thread that generated the
  #       log event.
  #  [%]  The sequence '%%' outputs a single percent sign.
  #
  # The directives F, L, and M will only work if the Logger generating the
  # events is configured to generate tracing information. If this is not
  # the case these fields will always be empty.
  #
  # By default the relevant information is output as is. However, with the
  # aid of format modifiers it is possible to change the minimum field width,
  # the maximum field width and justification.
  #
  # The optional format modifier is placed between the percent sign and the
  # conversion character.
  #
  # The first optional format modifier is the left justification flag which
  # is just the minus (-) character. Then comes the optional minimum field
  # width modifier. This is a decimal constant that represents the minimum
  # number of characters to output. If the data item requires fewer
  # characters, it is padded on either the left or the right until the
  # minimum width is reached. The default is to pad on the left (right
  # justify) but you can specify right padding with the left justification
  # flag. The padding character is space. If the data item is larger than the
  # minimum field width, the field is expanded to accommodate the data. The
  # value is never truncated.
  #
  # This behavior can be changed using the maximum field width modifier which
  # is designated by a period followed by a decimal constant. If the data
  # item is longer than the maximum field, then the extra characters are
  # removed from the end of the data item.
  #
  # Below are various format modifier examples for the category conversion
  # specifier.
  # 
  #  [%20c]      Left pad with spaces if the logger name is less than 20
  #              characters long
  #  [%-20c]     Right pad with spaces if the logger name is less than 20
  #              characters long
  #  [%.30c]     Truncates the logger name if it is longer than 30 characters
  #  [%20.30c]   Left pad with spaces if the logger name is shorter than
  #              20 characters. However, if the logger name is longer than
  #              30 characters, then truncate the name.
  #  [%-20.30c]  Right pad with spaces if the logger name is shorter than
  #              20 characters. However, if the logger name is longer than
  #              30 characters, then truncate the name.
  #
  # Below are examples of some conversion patterns.
  #
  #    %.1l, [%d %r #%p] %5l -- %c: %m\n
  #
  # This is how the Logger class in the Ruby standard library formats
  # messages. The main difference will be in the date format (the Pattern
  # Layout uses the ISO8601 date format).
  #
  class Pattern < ::Logging::Layout

    # :stopdoc:

    # Arguments to sprintf keyed to directive letters
    DIRECTIVE_TABLE = {
      'c' => 'event.logger',
      'd' => 'format_date',
      'F' => 'event.file',
      'l' => '::Logging::LNAMES[event.level]',
      'L' => 'event.line',
      'm' => :placeholder,
      'M' => 'event.method',
      'p' => 'Process.pid',
      'r' => 'Integer((Time.now-@created_at)*1000).to_s',
      't' => 'Thread.current.object_id.to_s',
      '%' => :placeholder
    }

    # Matches the first directive encountered and the stuff around it.
    #
    # * $1 is the stuff before directive or "" if not applicable
    # * $2 is the %#.# match within directive group
    # * $3 is the directive letter
    # * $4 is the stuff after the directive or "" if not applicable
    DIRECTIVE_RGXP = %r/([^%]*)(?:(%-?\d*(?:\.\d+)?)([a-zA-Z%]))?(.*)/m

    # default date format
    ISO8601 = "%Y-%m-%d %H:%M:%S"

    #
    # call-seq:
    #    Pattern.create_format_methods( pf, opts )
    #
    def self.create_format_methods( pf, opts )
      # first, define the format_date method
      unless opts[:date_method].nil?
        module_eval <<-CODE
          def pf.format_date
            Time.now.#{opts[:date_method]}
          end
        CODE
      else
        module_eval <<-CODE
          def pf.format_date
            Time.now.strftime "#{opts[:date_pattern]}"
          end
        CODE
      end

      # Create the format_str(event) method. This method will return format
      # string that can be used with +sprintf+ to format the data objects in
      # the given _event_.
      code = "def pf.format_str( event )\nsprintf(\""
      pattern = opts[:pattern]
      have_m_directive = false
      args = []

      while true
        m = DIRECTIVE_RGXP.match(pattern)
        code << m[1] unless m[1].empty?

        case m[3]
        when '%'
          code << '%%%%'   # this results in a %% in the format string
        when 'm'
          code << '%' + m[2] + 's'
          have_m_directive = true
        when *DIRECTIVE_TABLE.keys
          code << m[2] + 's'
          args << DIRECTIVE_TABLE[m[3]]
        when nil: break
        else
          raise ArgumentError, "illegal format character - '#{m[3]}'"
        end

        break if m[4].empty?
        pattern = m[4]
      end

      code << '", ' + args.join(', ') + ")\n"
      code << "end\n"
      module_eval code

      # Create the format(event) method
      if have_m_directive
        module_eval <<-CODE
          def pf.format( event )
            fmt = format_str(event)
            buf = ''
            event.data.each {|obj| buf << sprintf(fmt, format_obj(obj))}
            buf
          end
        CODE
      else
        class << pf; alias :format :format_str; end
      end
    end
    # :startdoc:

    #
    # call-seq:
    #    Pattern.new( opts )
    #
    # Creates a new Pattern layout using the following options.
    #
    #    :pattern       =>  "[%d] %-5l -- %c : %m\n"
    #    :date_pattern  =>  "%Y-%m-%d %H:%M:%S"
    #    :date_method   =>  'usec' or 'to_s'
    #
    # If used, :date_method will supersede :date_pattern.
    #
    def initialize( opts = {} )
      f = opts.delete(:obj_format)
      super(f)

      @created_at = Time.now

      pattern = "[%d] %-#{::Logging::MAX_LEVEL_LENGTH}l -- %c : %m\n"
      opts[:pattern] = pattern if opts[:pattern].nil?
      opts[:date_pattern] = ISO8601 if opts[:date_pattern].nil? and
                                       opts[:date_method].nil?
      Pattern.create_format_methods(self, opts)
    end

  end  # class Pattern
end  # module Layouts
end  # module Logging

# EOF
