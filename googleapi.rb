require 'net/http'
require 'net/https'
require 'rexml/document'


class GoogleAPI

	attr_reader :http
	attr_accessor :INSTREAM, :OUTSTREAM, :ERRSTREAM

	class AuthenticationError < Exception
	end

	class HTTPError < Exception
	end

	class HTTPstatus
		attr_reader :code,:version,:message,:body
		def initialize
			self.clear
		end
		def clear
			@code=nil
			@version=nil
			@message=nil
			@body=nil
		end
		def set(response)
			@code = response.code if response.code
			@version = response.http_version if response.http_version
			@message = response.message if response.message
			if response.body
				@body = response.body
				mat = @body.match(/reason=['"]([^'"]*)['"]/)
				@message += " (#{mat[1]})" if mat
			end
		end
	end

	def initialize(domain)
		@authtok = nil
		@email = nil
		@password = nil
		@http = HTTPstatus.new 
		@domain = domain
		@curobj = nil
		@INSTREAM = STDIN
		@ERRSTREAM = STDERR
		@OUTSTREAM = STDOUT
		@debug = 0
	end

	##
	# googleapi.login
	#
	# Prompt for email address, password
	# authenticate against Google
	# 
	# Parameters: 
	#  none
	#
	def login
		@ERRSTREAM.print 'Email address:'
		email = @INSTREAM.gets.chomp
		@ERRSTREAM.print 'Password:'
		begin
			%x{stty -echo}
			pass = @INSTREAM.gets.chomp
			@OUTSTREAM.puts
		ensure
			%x{stty echo}
		end
		dologin(email,pass)
	end

	# 
	# googleapi.dologin
	#
	# Authenticate using passed email and password
	#
	# Parameters:
	#
	#     email: email address
	#     passwd: plain-text password
	#
	def dologin(email,passwd)
		@email = email
		@password = passwd
		@http.clear
		http = Net::HTTP.new('www.google.com',443)
		http.open_timeout = 3 # in seconds
		http.read_timeout = 3 # in seconds
		http.use_ssl = true
		http.verify_mode = OpenSSL::SSL::VERIFY_NONE
		response = http.send_request("POST",
					     'https://www.google.com/accounts/ClientLogin',
					     "accountType=HOSTED&Email=#{email}&Passwd=#{passwd}&service=apps"
					    )
					    @http.set(response)
					    tmat = response.body.match(/^Auth=(.+)$/)
					    if tmat
						    @authtok = tmat[1]
					    else
						    raise AuthenticationError, "Authentication Failed"
					    end
	end

	def urlcall(url,method='GET',data=nil)
		@http.clear
		raise AuthenticationError,"Not logged in" if !@authtok
		http = Net::HTTP.new('apps-apis.google.com',443)
		http.use_ssl = true
		http.verify_mode = OpenSSL::SSL::VERIFY_NONE
		response = http.send_request(method,url,data,{ 
			"Content-type" => "application/atom+xml", 
			"Authorization" => "GoogleLogin auth=#{@authtok}" 
		})
		@http.set(response)
		raise HTTPError,"Error #{@http.code}: #{@http.message}" if !response.code.match(/^2\d\d/)
		response.body
	end

	def readfeed(atomxml,baseclass=nil)
		root = REXML::Document.new(atomxml)
		return nil if (root.elements.count < 1) or !root.elements[1].name.match(/^entry$|^feed$/i)
		if baseclass == nil
			root.elements[1].elements.each do |el|
				if el.name == 'id'
					next if !el.text
					baseclass = Userentry if el.text.match(/\/user\//)
					baseclass = Nicknameentry if el.text.match(/\/nickname\//)
					baseclass = Groupentry if el.text.match(/\/group\//)
					baseclass = Memberentry if el.text.match(/\/member\//)
					baseclass = Ownerentry if el.text.match(/\/owner\//)
				end
			end
		end
		raise ArgumentError,"Could not determine class from XML" unless baseclass
		if root.elements[1].name == 'entry'
			begin
				return baseclass.new(atomxml)
			rescue ArgumentError => e
				@OUTSTREAM.puts "ArgumentError: #{e.message}"
			end
		else
			list=[]
			root.elements[1].elements.each do |el|
				begin
					list << baseclass.new(el) if el.name == 'entry'
				rescue ArgumentError => e
					@OUTSTREAM.puts "ArgumentError: #{e.message}"
				end
			end
			return list
		end
	end

	def inputfile(filename)
		if @OLDINSTREAM
			@OUSTSTREAM.puts "Input stream already redirected"
		else
			begin
				tfile = File.open(filename,'r')
				@OLDINSTREAM = @INSTREAM
				@INSTREAM = tfile
			rescue Errno::ENOENT => e
				@OUTSTREAM.puts "File '#{filename}' not found."	
			end
		end
	end

	def openpipe(filename)
		if @OLDOUTSTREAM
			@OUTSTREAM.puts "Pipe already active"
		else
			begin
				tfile = File.open(filename,'a+')
				def tfile.oldstream(stream)
					@OLDOUTSTREAM = stream
				end
				def tfile.print(*args)
					@OLDOUTSTREAM.print(*args)
					super(*args)
				end
				def tfile.nputs(*args)
					self.puts(*args)
				end
				def tfile.puts(*args)
					@OLDOUTSTREAM.puts(*args) if !caller(1)[0].match(/in .nputs./)
					super(*args)
				end
				tfile.oldstream(@OUTSTREAM)

				@OLDOUTSTREAM = @OUTSTREAM
				@OUTSTREAM = tfile
				@OUTSTREAM.puts "Pipe opened to #{filename}"
			rescue Exception => e
				@OUTSTREAM.puts "#{e.name}: #{e.message}"
			end
		end
	end

	def closepipe
		if @OLDOUTSTREAM
			@OUTSTREAM.puts "Closing pipe to #{@OUTSTREAM.path}"
			@OUTSTREAM.close
			@OUTSTREAM = @OLDOUTSTREAM
			@OLDOUTSTREAM = nil
			@OUTSTREAM.puts "Pipe closed"
		else
			@OUTSTREAM.puts "No pipe to close"
		end
	end

	def safedump(obj,labels=true)
		if obj.respond_to?("apidump")
			@OUTSTREAM.puts obj.apidump(labels)
		else
			@OUTSTREAM.puts obj.inspect
		end
	end

	def dumpobj(obj=@curobj)
		return if !obj
		if obj.class == Array
			return if obj.length < 1
			obj.sort! if obj[0].respond_to?('<=>')
			@OUTSTREAM.puts obj[0].dumplabels if obj[0].respond_to?("dumplabels")
			obj.each_with_index do |o,i| 
				@OUTSTREAM.print "%#{obj.length.to_s.length}i)"%(i.to_s)
				safedump(o,false)
			end
		else
			safedump(obj)
		end
	end

	def help(section='all')
		section = 'all' unless section.class == String
		section.downcase!
		section = 'all' unless ['create','update','delete','get','group','misc'].include?(section)
		if (section == 'all')
			@OUTSTREAM.puts "Basic Commands"
			@OUTSTREAM.puts "\t parameters marked with {} are optional, but will be taken from the current object if one exists"
		end
		if (section == 'all') or (section == 'create')
			@OUTSTREAM.puts "Object creation(local):"
			@OUTSTREAM.puts "\tnew user <username> [<firstname> <lastname> <password> <forcepwchange> <admin> <quota> <suspended>]" 
			@OUTSTREAM.puts "\tnew group <groupid> <groupname> [<description> <emailperm>]"
			@OUTSTREAM.puts "\tnew nickname <username> <nickname>"
			@OUTSTREAM.puts "\tnew member <id>"
			@OUTSTREAM.puts "\tnew owner <email>"
			@OUTSTREAM.puts "\tnew <user|nickname|member|group|owner> (without params)-  create an object of the specified type and prompt for details"
			@OUTSTREAM.puts "\t\tAll of the above set the current object to the newly created object"
			@OUTSTREAM.puts "\nObject creation(remote):"
			@OUTSTREAM.puts "\tcreateuser\n\tcreatenickname\n\tcreategroup"
			@OUTSTREAM.puts "\t\tcreate a remote object from the current object"
			@OUTSTREAM.puts "\tcreate - infer one of the above based on the current object"
		end
		if (section == 'all') or (section == 'update')
			@OUTSTREAM.puts "\nObject update(local):"
			@OUTSTREAM.puts "set <parameter> [<value>] - set <parameter> of the current object to <value> - prompt if value is not specified"
			@OUTSTREAM.puts "\nObject update(remote):"
			@OUTSTREAM.puts "\tupdateuser\n\tupdategroup\n\t\tUpdate the remote object with the current object"
			@OUTSTREAM.puts "\tupdate - infer one of the above based on the type of the current object"
		end
		if (section == 'all') or (section == 'delete')
			@OUTSTREAM.puts "\nObject Deletetion(remote):"
			@OUTSTREAM.puts "\tdeletegroup|delgroup {<groupid>} - delete a group"
			@OUTSTREAM.puts "\tdeleteuser|deluser {<username>} - delete a user"
			@OUTSTREAM.puts "\tdeletenickname|delnickname {<nickname>} - delete a nickname"
			@OUTSTREAM.puts "\tdelete|del - infer one of the above based on the current object"
		end
		if (section == 'all') or (section == 'get')
			@OUTSTREAM.puts "\nObject retrieval(remote):"
			@OUTSTREAM.puts "\tgetuser {<username>} - retrieve user, list of users if not specified"
			@OUTSTREAM.puts "\tgetnickname {<nickname>} - return nickname, list of all nicknames if not specified"
			@OUTSTREAM.puts "\tgetusernickname {<username>} - return list of nicknames for user, list of all nicknames if not specified"
			@OUTSTREAM.puts "\tgetgroup {<groupid>} - return group, list of groups if not specified"
		end
		if (section == 'all') or (section == 'group')
			@OUTSTREAM.puts "\nGroups:"
			@OUTSTREAM.puts "\taddmember <groupid> - add current object of type member to groupid"
			@OUTSTREAM.puts "\tgetmember {<groupid>} - return the list of current members of groupid - all groups if no current object"
			@OUTSTREAM.puts "\tgetmemberof {<groupid>|<username>} - list groups of which the specified group or user is a member - all groups if no current object"
			@OUTSTREAM.puts "\tremovemember <groupid> {<member>} - remove member from the group"
			@OUTSTREAM.puts "\tgetowner {<groupid>} - return current owner of the group"
			@OUTSTREAM.puts "\tsetowner <groupid> {<owner>} - set current owner of the group"
			@OUTSTREAM.puts "\tremoveowner <groupid> {<owner>} - remove the owner from the group"
		end
		if (section == 'all') or (section == 'misc')
			@OUTSTREAM.puts "\nMisc:"
			@OUTSTREAM.puts "\tselect <index> - select a specific item when current object is an array"
			@OUTSTREAM.puts "\tpipe <filename> - duplicate(tee) output to filename"
			@OUTSTREAM.puts "\tnopipe - terminate pipe"
			@OUTSTREAM.puts "\tshow - display current object"
			@OUTSTREAM.puts "\tprompt [<text>] - set prompt to text, GoogleAPI if not specified. Note: type of the current object will be appended"
			@OUTSTREAM.puts "\thttp.code - return http status code of the last remote operation"
			@OUTSTREAM.puts "\thttp.message - return http status message of the last remote operation"
			@OUTSTREAM.puts "\thttp.body - return http body from the last remote operation"
			@OUTSTREAM.puts "\thelp [create|delete|get|update|group|misc] - display help"
			@OUTSTREAM.puts "\texit|quit|bye - exit"
		end
	end

	def self.cli
		if !@domain
			@OUTSTREAM.print "Domain: "
			domain = @INSTREAM.gets
			inst = self.new(domain)
			inst.cli
		end
	end

	def cli
		#process command after it's been split by word
		def clicmd(words)
			case words[0].downcase
			#explicitly defined commands first
			when 'debug':
				if words[1]
					@debug = words[1].to_i
				else
					@debug = 1
				end	
			when 'new','make':
				@curobj = nil
				cname = words[1].downcase.capitalize + 'entry' if words[1]
				if Class.constants.include?(cname)
					klass = eval cname 
					if words.length > 2
						@curobj = klass.new(*words[2..-1])
					else
						@curobj = klass.promptnew(@INSTREAM,@OUTSTREAM)
					end
					dumpobj
				else
					@OUTSTREAM.puts "Unknown object type #{words[1]}"
				end
			when 'show','@curobj': 
				if @curobj
					dumpobj
				else
					@OUTSTREAM.puts "No current object"
				end
			when 'clear': @curobj = nil
				@OUTSTREAM.puts "Current object cleared"
			when 'read':
				if words.length < 2
					@OUTSTREAM.puts "Must spcify file name"
				else
					self.inputfile(words[1])
				end
			when 'pipe': 
				if words.length < 2
					@OUTSTREAM.puts "Must specify file name"
				else
					self.openpipe(words[1])
				end
			when 'nopipe': self.closepipe
			when 'prompt': 
				@prompt = words[1..-1].join(" ")
				@prompt = "GoogleAPI" if words.length == 1
			when 'edit','modify','set':
				if (words.length > 1) and @curobj.respond_to?("#{words[1]}") and @curobj.respond_to?("#{words[1]}=")
					if words.length == 3
						val = words[2]
					else
						@OUTSTREAM.puts "Current: #{words[1]}=#{@curobj.send(words[1])}"
						@OUTSTREAM.print "#{words[1]}:"
						val = @INSTREAM.gets.chomp
					end
					case val.downcase
					when 'true','yes': val = true
					when 'false','no': val = false
					when '': val = nil
					end
					@OUTSTREAM.puts "Setting #{words[1]} to #{val}"
					@curobj.send("#{words[1]}=",val)
					@OUTSTREAM.puts @curobj.apidump if @curobj.respond_to?("apidump")
				else
					@OUTSTREAM.puts "Invalid variable name #{words[1]}"
				end
			when 'select':
				if @curobj.class == Array
					if words[1].match(/[0-9]*/) and words[1].to_i < @curobj.length
						@curobj = @curobj[words[1].to_i]
						dumpobj
					else
						@OUTSTREAM.puts "Invalid index #{words[1]}"
					end
				else
					@OUTSTREAM.puts "#{@curobj.class.name} not array"
				end
			else
				method = words[0].split('.')[0] #see if the typed command matches a method name
				objmeth = "#{method}#{@curobj.class.name.downcase.gsub("entry","")}" #also see if we can infer the method based on the current object
				@OUTSTREAM.puts "method: #{method} (#{self.respond_to?(method)})\nobjmeth: #{objmeth} (#{self.respond_to?(objmeth)})\nobjclass: #{@curbj ? @curobj.class.name.gsub(/entry$/,"") : 'None'}" if @debug > 1
#				if !self.respond_to?(method) and self.respond_to?(objmeth) and (!words[1] or (words[1].downcase != @curobj.class.name.gsub(/entry$/,"").downcase)) and ((words.length - 1) <= self.class.instance_method(objmeth).arity.abs)
				if !self.respond_to?(method) and self.respond_to?(objmeth) and (!words[1] or !Class.constants.include?("#{words[1].capitalize}entry")) and ((words.length - 1) <= self.class.instance_method(objmeth).arity.abs)
					words[0] = objmeth 
				end

				if self.respond_to?(words[0].split('.')[0])
					if @curobj and 
					   @curobj.respond_to?("objid") and
					   (words.length - 1) < self.class.instance_method(words[0]).arity.abs
						@OUTSTREAM.puts "calling #{words[0]} using current object (#{@curobj.class.name}{#{@curobj.objid}})"
						words[words.length] = @curobj 
					end
					@OUTSTREAM.puts "method valid" if @debug > 5
					ret = call_meth(self,words[0],words[1..-1])
					dumpobj(ret)
				#then do some simple checking to see if removing spaces makes it match
				elsif words[0].match(/^new|^make/) and Class.constants.include?("#{words[0][3..-1].capitalize}entry")
					cmdary = ["new",words[0][3..-1]] + [words[1..-1]].reject{ |i| i == nil }.flatten
					@OUTSTREAM.puts "Assuming you meant '#{cmdary.join(" ")}'"
					clicmd(cmdary)
				elsif words[0..3].join("").match(/^(getusernickname|getmemberof)$/)
				       cmdary = [words[0..3].join("")] + [words[4..-1]].reject{ |i| i == nil }.flatten	
				       @OUTSTREAM.puts "Assuming you meant '#{cmdary.join(" ")}'"
				       clicmd(cmdary)	
				elsif words[0..2].join("").match(/^(((get|delete|del|getuser)nickname)|getmemberof)$/)
				       cmdary = [words[0..2].join("")] + [words[3..-1]].reject{ |i| i == nil }.flatten
				       @OUTSTREAM.puts "Assuming you meant '#{cmdary.join(" ")}'"
				       clicmd(cmdary)	
				elsif words[0..1].join("").match(/^((get(user|group|nickname|member|owner))|addmember|(remove(member|owner))|((delete|del)(group|user|nickname))|setowner)$/)
					cmdary = [words[0..1].join("")] + [words[2..-1]].reject{ |i| i == nil }.flatten
					@OUTSTREAM.puts "Assuming you meant '#{cmdary.join(" ")}'"
					clicmd(cmdary)	
				else
				#ok, I can't find it
					@OUTSTREAM.puts "undefined method #{words[0]}"
				end
			end
		end

		def call_meth(obj,meth,args=[])
			@OUTSTREAM.puts "Call method #{meth} with #{args.inspect}" if @debug > 5
			if meth.match(/\./)
				kid = obj.send(meth.split('.')[0])
				return call_meth(kid,meth.match(/^[^\.]*\.(.*)$/)[1],args)
			else
				return obj.send(meth.to_sym,*args)
			end
		end

		@prompt = "GoogleAPI" if !@prompt
		@OUTSTREAM.print "#{@prompt}>"
		@curobj = nil
		#This is the CLI 'event loop'
		while !(cmd = @INSTREAM.gets.chomp).match(/^exit$|^quit^|^bye$/i) do
			if cmd and cmd.length > 0
				@OUTSTREAM.nputs cmd if @OUTSTREAM.respond_to?("nputs")
				begin
					words = cmd.gsub(/'[^']*'|"[^"]*"/){ |s| s.gsub(" ","+|+") }.split
					words.each{ |w| w.gsub!("+|+"," ");w.gsub!(/['"]/,"") }
					words.each_with_index{ |w,i| @OUTSTREAM.puts "#{i})#{w}" } if @debug > 1
					clicmd(words)
				rescue Exception => e
					@OUTSTREAM.puts "#{e.class}: #{e.message}"
					e.backtrace.each { |b| @OUTSTREAM.puts b } if @debug > 0
				end
			else
				@OUTSTREAM.puts %x{fortune}
			end
			if @OLDINSTREAM and @INSTREAM.eof
				@INSTREAM = @OLDINSTREAM
				@OLDINSTREAM = nil
			end
			@OUTSTREAM.print "\n#{@prompt}#{"(#{@curobj.class.name}#{"[#{@curobj[0].class.name}]" if @curobj.class == Array and @curobj.length > 0})" if @curobj}>"
		end
	end

	def getuser(username=nil)
		username = username.username if username.class == Userentry
		username = nil unless username.class == String
		@curobj = readfeed(urlcall("https://apps-apis.google.com/a/feeds/#{@domain}/user/2.0/#{username}"),Userentry)
	end

	def createuser(userxml)
		userxml = userxml.to_xml if userxml.class == Userentry
		username = Userentry.new(userxml).username
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/#{@domain}/user/2.0","POST",userxml),Userentry)
	end

	alias adduser createuser

	def updateuser(userxml)
		userxml = userxml.to_xml if userxml.class == Userentry
		@OUTSTREAM.puts userxml if @debug > 2
		username = Userentry.new(userxml).username
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/#{@domain}/user/2.0/#{username}","PUT",userxml),Userentry)
	end


	alias renameuser updateuser

	def deleteuser(username)
		username = username.username if username.class == Userentry
		raise ArgumentError,"Invalid username" unless username.class == String
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/#{@domain}/user/2.0/#{username}","DELETE"),Userentry)
	end

	alias deluser deleteuser

	def getnickname(nickname=nil)
		nickname = nickname.nickname if nickname.class == Nicknameentry
		nickname = nil unless nickname.class == String
		@curobj = readfeed(urlcall("https://apps-apis.google.com/a/feeds/#{@domain}/nickname/2.0/#{nickname}"),Nicknameentry)
	end

	def getusernicknames(username=nil)
		username = username.username if (username.class == Nicknameentry) or (username.class == Userentry)
		username = nil unless username.class == String
		@curobj = readfeed(urlcall("https://apps-apis.google.com/a/feeds/#{@domain}/nickname/2.0/#{"?username=#{username}" if username}"),Nicknameentry)
	end

	def createnickname(nickxml)
		nickxml = nickxml.to_xml if nickxml.class == Nicknameentry
		begin
			readfeed(urlcall("https://apps-apis.google.com/a/feeds/#{@domain}/nickname/2.0","POST",nickxml),Nicknameentry)	
		rescue HTTPError => e
			if @http.body.match(/reason="EntityExists"/)
				nickname = Nicknameentry.new(nickxml).nickname
				@OUTSTREAM.puts "Nickname #{nickname} already exists"
			else
				raise e
			end
		end

	end

	alias addnickname createnickname

	def deletenickname(nickname)
		nickname = nickname.nickname if nickname.class == Nicknameentry
		raise ArgumentError,"Invalid nickname" unless nickname.class == String
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/#{@domain}/nickname/2.0/#{nickname}","DELETE"),Nicknameentry)
	end

	alias delnickname deletenickname

	def creategroup(groupxml)
		groupxml = groupxml.to_xml if groupxml.class == Groupentry
		raise ArgumentError,"Invalid XML" unless groupxml.class == String
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}","POST",groupxml),Groupentry)
	end

	alias addgroup creategroup

	def updategroup(groupxml)
		groupxml = groupxml.to_xml if groupxml.class == Groupentry
		groupid = Groupentry.new(groupxml).id
		raise ArgumentError,"Invalid group id" unless groupid
		raise ArgumentError,"Invalid XML" unless groupxml.class == String
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}/#{groupid}","PUT",groupxml),Groupentry)
	end

	def getmemberof(memberid=nil,direct=true)
		memberid = memberid.id if (memberid.class == Memberentry) or (memberid.class == Groupentry)
		memberid = memberid.username if (memberid.class == Userentry) or (memberid.class == Nicknameentry)
		memberid = memberid.email if memberid.class == Ownerentry
		memberid = nil unless memberid.class == String
		getstr="?member=#{memberid}&directOnly=#{direct ? 'true' : 'false'}" if memberid
		@curobj = readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}/#{getstr}"),Groupentry)
	end

	def  getgroup(groupid = nil)
		groupid = groupid.id if groupid.class == Groupentry
		groupid = nil unless groupid.class == String
		@curobj = readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}/#{groupid}"),Groupentry)
	end

	alias getgroups getgroup

	def deletegroup(groupid)
		groupid = groupid.id if groupid.class == Groupentry
		raise ArgumentError,"Invalid group id" unless groupid.class == String
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}/#{groupid}","DELETE"),Groupentry)
	end

	alias delgroup deletegroup

	def addmember(groupid,memberxml)
		groupid = groupid.id if groupid.class == Groupentry
		memberxml = memberxml.to_xml if memberxml.class == Memberentry
		memberxml = Memberentry.new(memberxml).to_xml if memberxml.class == String
		memberxml = Memberentry.new(memberxml.username).to_xml if memberxml.class == Userentry 
		raise ArgumentError,'Invalid group id' unless groupid.class == String
		raise ArgumentError,"Invalid XML" unless memberxml.class == String
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}/#{groupid}/member","POST",memberxml),Memberentry)
	end

	def getmember(groupid=nil,memberid=nil)
		return getmemberof if groupid == nil
		groupid = groupid.id if groupid.class == Groupentry
		raise ArgumentError,"Invalid group id" unless groupid.class == String
		memberid = memberid.id if memberid.class == Memberentry
		memberid = memberid.username if memberid.class == Userentry
		memberid = nil unless memberid.class == String
		@curobj = readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}/#{groupid}/member/#{memberid}"),Memberentry)
	end

	def removemember(groupid,memberid)
		groupid = groupid.id if groupid.class == Groupentry
		raise ArgumentError,"Invalid group id" unless groupid.class == String
		memberid = memberid.id if memberid.class == Memberentry
		memberid = memberid.username if memberid.class == Userentry
		raise ArgumentError,"Invalid member id" unless memberid.class == String
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}/#{groupid}/member/#{memberid}","DELETE"),Memberentry)
	end

	alias remmember removemember

	def setowner(groupid,ownerxml)
		groupid = groupid.id if groupid.class == Groupentry
		raise ArgumentError,"Invalid group id" unless groupid.class == String
		ownerxml = ownerxml.to_xml if ownerxml.class == Ownerentry
		raise ArgumentError,"Invalid XML" unless ownerxml.class == String
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}/#{groupid}/owner","POST",ownerxml),Ownerentry)
	end

	def getowner(groupid,owneremail)
		groupid = groupid.id if groupid.class == Groupentry
		raise ArgumentError,"Invalid group id" unless groupid.class == String
		owneremail = owneremail.email if owneremail.class == Ownerentry
		owneremail = nil unless owneremail.class == String
		@curobj = readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}/#{groupid}/owner/#{owneremail}"),Ownerentry)
	end

	def removeowner(groupid,owneremail)
		groupid = groupid.id if groupid.class == Groupentry
		raise ArgumentError,"Invalid group id" unless groupid.class == String
		owneremail = owneremail.email if owneremail.class == Ownerentry
		raise ArgumentError,"Invalid owner email" unless owneremail.class == String
		readfeed(urlcall("https://apps-apis.google.com/a/feeds/group/2.0/#{@domain}/#{groupid}/owner/#{owneremail}","DELETE"),Ownerentry)
	end
end


class Apientry
	def initialize
		raise ArgumentError,"Attempt to initialize abstract class Apientry"
	end
	def to_xml
		'<?xml version="1.0" encoding="UTF-8"?>' + self.to_atom
	end

	def dumplabels
		dumpstr = "#{self.class.to_s}:\n"
		dumpstr += self.instance_variables.sort.map{ |v| "#{v}" }.join(",")
	end

	def apidump(labels=true)
		dumpstr = ""
		dumpstr += dumplabels + "\n" if labels
		dumpstr += self.instance_variables.sort.map{ |v| "#{self.send(v.gsub("@","").to_sym)}" }.join(",")
	end

	def self.promptnew(instream=STDIN,outstream=STDOUT)
		vhash = {}
		self.public_instance_methods.find_all{ |m| m.match(/[^=]=$/)}.each do |v|
			m = v.match(/^[@]*(.*)=$/)
			v = m[1]
			outstream.print "#{v}:"
			val = instream.gets.chomp
			case val.downcase
			when 'true','yes': val = true
			when 'false','no': val = false
			when '': val = nil
			end
			vhash[v] = val
		end
		self.hashnew(vhash)
	end


	def getroot(atomxml)
		if atomxml.class == REXML::Element
			root = atomxml
		else
			doc = REXML::Document.new(atomxml)
			if (doc.elements.count < 1) or (doc.elements[1].name != 'entry')
				root = nil
			else
				root = doc.elements[1]
			end
		end
		root
	end

	def objid
		@id
	end

	def makebool(val)
		return true if (val.class == TrueClass) or (val.to_s.chomp.downcase.match(/^true$|^yes$|^y$|^ok$|^1$/))
		return false
	end

	def urlencode(string)
		string.gsub(/([^ a-zA-Z0-9@_.-]+)/n) { |c| '%' + c.unpack('H2' * $1.size).join('%').upcase }
	end
end

class Nicknameentry < Apientry
	attr_accessor :username, :nickname

	def self.hashnew(h)
		new(h['username'],h['nickname'])
	end

	def initialize(user,nick=nil)
		if nick
			@username = user
			@nickname = nick
		else
			root = self.getroot(user)
			raise ArgumentError,"Wrong number of arguments (1 for 2)" if !root
			root.elements.each do |el|
				@username = el.attributes['userName'] if el.name == 'login'
				@nickname = el.attributes['name'] if el.name == 'nickname'
			end
		end
	end

	def to_atom
		'<atom:entry xmlns:atom="http://www.w3.org/2005/Atom" xmlns:apps="http://schemas.google.com/apps/2006">' +
			'<atom:category scheme="http://schemas.google.com/g/2005#kind" term="http://schemas.google.com/apps/2006#nickname"/>' +
			'<apps:nickname name="' + urlencode(@nickname.to_s) + '"/>' +
			'<apps:login userName="' + urlencode(@username.to_s) + '"/>' +
			'</atom:entry>'
	end
	def objid
		"#{@nickname} -> #{@username}"
	end
	def <=> (b)
		raise ArgumentError,"Invalid comparison of #{self.class} with #{b.class}" unless b.class == self.class
		return "#{self.nickname}\000#{self.username}" <=> "#{b.nickname}\000#{b.username}"
	end
end

class Userentry < Apientry

	attr_accessor :username, :password, :quota, :firstname, :lastname
	attr_reader :admin, :forcepwchange, :agreedtoterms, :suspended

	def self.hashnew(h)
		new(h['username'],h['firstname'],h['lastname'],h['password'],h['forcepwchange'],h['admin'],h['quota'],h['suspended'])
	end
	def initialize(username, firstname=nil, lastname=nil, password=nil, forcepwchange=nil, admin=nil, quota=nil, suspended=nil)
		@username = username
		@firstname = firstname
		@lastname = lastname
		@password = password
		@forcepwchange = forcepwchange
		@admin = admin
		@quota = quota
		@suspended = suspended
		@agreedtoterms = true

		if !firstname and !lastname and !password and !quota and (forcepwchange == nil) and (admin==nil) and (suspended == nil) 	
			root = self.getroot(username) || REXML::Element.new
			if root.name == 'entry'
				@username = nil
				root.elements.each do |el|
					case (el.name) 
					when 'login':
						@username = el.attributes['userName']
						@password = el.attributes['password']
						@suspended = (el.attributes['suspended'].downcase == 'true')
						@admin = (el.attributes['admin'].downcase == 'true')
						@forcepwchange = (el.attributes['changePasswordAtNextLogin'].downcase == 'true')
						@agreedtoterms = (el.attributes['agreedToTerms'].downcase == 'true') if el.attributes.include?('agreedToTerms')
					when 'quota':
						@quota = el.attributes['limit']
					when 'name':
						@firstname = el.attributes['givenName']
						@lastname = el.attributes['familyName']
					end
				end
				raise ArgumentError,"User not specified by XML" unless @username
			end

		end
		def admin=(val)
			@admin = makebool(val)
		end
		def forcepwchange=(val)
			@forcepwchange = makebool(val)
		end
		def agreedtoterms=(val)
			@agreedtoterms = makebool(val)
		end
		def suspended=(val)
			@suspended = makebool(val)
		end
		def objid
			@username
		end
		def <=> (b)
			raise ArgumentError,"Invalid comparison of #{self.class} with #{b.class}" unless b.class == self.class
			"#{self.lastname}\000#{self.firstname}\000#{self.username}" <=> "#{b.lastname}\000#{b.firstname}\000#{b.username}"
		end
	end

	def to_atom
		atomxml = '<atom:entry xmlns:atom="http://www.w3.org/2005/Atom" xmlns:apps="http://schemas.google.com/apps/2006">' 
		atomxml += '<atom:category scheme="http://schemas.google.com/g/2005#kind" term="http://schemas.google.com/apps/2006#user"/>' 
		atomxml += '<apps:login userName="' + urlencode(@username) + '"' 
		atomxml += " password=\"#{urlencode(@password)}\" " if @password
		atomxml += ' changePasswordAtNextLogin="' + (@forcepwchange ? 'true' : 'false') + '"'
		atomxml += ' agreedToTerms="true"' if @agreedtoterms
		atomxml += ' admin="' + (@admin ? 'true' : 'false') + '"'
		atomxml += ' suspended="' + (@suspended ? 'true' : 'false') + '"/>' 
		atomxml += "<apps:quota limit=\"#{urlencode(@quota)}\"/>" if @quota
		if @firstname or @lastname
			atomxml += "'<apps:name "
			atomxml += "familyName=\"#{urlencode(@lastname)}\" " if @lastname
			atomxml += "givenName=\"#{urlencode(@firstname)}\" " if @firstname
			atomxml += '/>'
		end
		atomxml += '</atom:entry>'
	end
end

class Groupentry < Apientry
	attr_accessor :id, :name, :description
	attr_reader :emailperm

	def self.hashnew(h)
		inst = new(h['id'],h['name'],h['description'],h['emailperm'])
	end


	def initialize(groupid,groupname=nil,description='',emailperm='Anyone') 
		root = self.getroot(groupid)
		if !root
			@id = groupid
			@name = groupname || groupid
			self.emailperm = emailperm
			@description = description
		else
			root.elements.each do |el|
				if el.name == 'property'
					case el.attributes['name']
					when 'groupId': @id = el.attributes['value']
					when 'groupName': @name = el.attributes['value']
					when 'description': @description = el.attributes['value']	
					when 'emailPermission': @emailperm = el.attributes['value']
					end
				end
			end
		end
	end

	def emailperm=(perm)
		raise ArgumentError,"emailperm must be one of: Owner Member Domain Anyone" unless perm.class == String and perm.match(/^owner$|^domain$|^member$|^anyone$/i)
		@emailperm = perm.downcase.capitalize
	end

	def <=> (b)
		raise ArgumentError,"Invalid comparison of #{self.class} with #{b.class}" unless b.class == self.class
		"#{self.name}\000#{self.id}" <=> "#{b.name}\000#{b.id}"
	end

	def to_atom
		atomxml = '<atom:entry xmlns:atom="http://www.w3.org/2005/Atom" xmlns:apps="http://schemas.google.com/apps/2006" xmlns:gd="http://schemas.google.com/g/2005">'
		atomxml += '<apps:property name="groupId" value="' + urlencode(@id) + '"></apps:property>' if @id
		atomxml += '<apps:property name="groupName" value="' + urlencode(@name) + '"></apps:property>' if @name
		atomxml += '<apps:property name="description" value="' + urlencode(@description) + '"></apps:property>' if @description
		atomxml += '<apps:property name="emailPermission" value="' + @emailperm + '"></apps:property>' if @emailperm
		atomxml += '</atom:entry>'
	end
end


class Memberentry < Apientry
	attr_accessor :id
	attr_reader :type, :direct

	def self.hashnew(h)
		new(h['id'])
	end

	def initialize(id)
		@id=id
		@type=nil
		@direct=nil
		root = self.getroot(id)
		if root.class.name.match(/REXML/)
			@id = nil
			raise ArgumentError,"Invalid Atom/XML" if (root.name != 'entry')
			root.elements.each do |el|
				if el.name == 'property'
					case el.attributes['name']
					when 'memberId': @id = el.attributes['value']
					when 'memberType': @type = el.attributes['value']
					when 'directMember': @direct = (el.attributes['value'].downcase == 'true')
					end
				end
			end
			raise ArgumentError,"Member ID not specified by XML" unless @id
		end
	end

	def <=> (b)
		raise ArgumentError,"Invalid comparison of #{self.class} with #{b.class}" unless b.class == self.class
		"#{self.id}" <=> "#{b.id}"
	end

	def to_atom
		atomxml = '<atom:entry xmlns:atom="http://www.w3.org/2005/Atom" xmlns:apps="http://schemas.google.com/apps/2006" xmlns:gd="http://schemas.google.com/g/2005">'
		atomxml += '<apps:property name="memberId" value="' + urlencode(@id) + '"/>' if @id
		atomxml += '<apps:property name="memberType" value="' + urlencode(@type) + '"/>' if @type
		atomxml += '<apps:property name="directMember" value="' + (@direct ? 'true' : 'false') + '/>' if @direct != nil and caller.find_all{ |z| z.match(/`add|`new/i) }.length == 0
		atomxml += '</atom:entry>'
	end
end

class Ownerentry < Apientry
	attr_accessor :email

	def self.hashnew(h)
		new(h['email'])
	end

	def initialize(email)
		@email = email
		root = self.getroot(email)
		if root.class.name.match(/REXML/)
			@email = nil
			raise ArgumentError,"Invalid Atom/XML" if (root.name != 'entry')
			root.elements.each do |el|
				@email = el.attributes['value']	if (el.name == 'property') and (el.attributes['name'] == 'email')
			end
			raise ArgumentError,"Email address not specified by XML" unless @email
		end
	end

	def <=> (b)
		raise ArgumentError,"Invalid comparison of #{self.class} with #{b.class}" unless b.class == self.class
		"#{self.email}" <=> "#{b.email}"
	end

	def to_atom
		atomxml = '<atom:entry xmlns:atom="http://www.w3.org/2005/Atom" xmlns:apps="http://schemas.google.com/apps/2006" xmlns:gd="http://schemas.google.com/g/2005">'
		atomxml += '<apps:property name="email" value="' + urlencode(@email) + '"/>' if @email
		atomxml += '</atom:entry>'
	end

	def objid
		@email
	end
end 
