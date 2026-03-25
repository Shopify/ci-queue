# frozen_string_literal: true
module OutputTestHelpers
  PROJECT_ROOT_PATH = File.expand_path('../../../', __FILE__)
  private

  def strip_blank_lines(output)
    output.lines.map { |l| l.strip.empty? ? "\n" : l }.join
  end

  def decolorize_output(output)
    output.to_s.gsub(/\e\[\d+m/, '')
  end

  def strip_heredoc(heredoc)
    indent = heredoc.scan(/^[ \t]*(?=\S)/).min.size || 0
    heredoc.gsub(/^[ \t]{#{indent}}/, '')
  end

  def freeze_timing(output)
    output.to_s.gsub(/\d+\.\d+s/, 'X.XXs').gsub(/ \d+(\.\d+)? seconds /, ' X.XXXXX seconds ')
  end

  def freeze_seed(output)
    output.to_s.gsub(/\-\-seed \d+/, '--seed XXXXX')
  end

  def rewrite_paths(output)
    output.to_s.gsub(PROJECT_ROOT_PATH, '.')
  end

  def freeze_xml_timing(output)
    output.gsub(/time="[\d\-\.e]+"/, 'time="X.XX"').gsub(/timestamp="[\d\-\.e]+"/, 'timestamp="X.XX"')
  end

  def normalize_backtrace(output)
    output.to_s.gsub(/in '([^']+)'/) do
      "in `#{$1.sub(/\A[A-Z][\w]*(?:::[A-Z][\w]*)*[#.]/, '')}'"
    end
  end

  def normalize(output)
    normalize_backtrace(freeze_timing(decolorize_output(output)))
  end

  def filter_deprecation_warnings(output)
    output.to_s.lines.reject do |line|
      line.include?("was loaded from the standard library, but will no longer be part of the default gems") ||
        line.include?("You can add") && (line.include?("to your Gemfile or gemspec to silence this warning") || line.include?("to your Gemfile or gemspec to fix this error")) ||
        line.include?("is not part of the default gems since Ruby") ||
        line.include?("warning: already initialized constant") ||
        line.include?("warning: previous definition of")
    end.join
  end
end
