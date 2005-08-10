require "nkf"

class MyFilter < Plugin
  def filter(mail)
    if /root@/.match(mail.header["to"])
      return "static/root"
    end
    case mail.header["from"]
    when /shugo@ruby-lang.org/
      return "from/shugo"
    when /oguhs@ruby-lang.org/
      return "from/oguhs"
    end
    if /[未末]承諾広告/u.match(NKF.nkf("-mw", mail.header["subject"].to_s))
      return "spam"
    end
    return nil
  end
end
