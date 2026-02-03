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

  def normalize(output)
    freeze_timing(decolorize_output(output))
  end

  # Find the test summary line (e.g., "Ran 2 tests, 2 assertions, ...")
  # This is more robust than assuming it's the last line since worker stats may follow
  def find_summary_line(output)
    output.lines.reverse.find { |line| line =~ /Ran \d+ tests,/ }&.strip
  end

  # Normalize the memory value in worker stats output
  def normalize_worker_stats(output)
    output.gsub(/\d+ MB peak memory/, 'X MB peak memory')
  end
end
