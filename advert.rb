class Advert < ActiveRecord::Base

  include Rails.application.routes.url_helpers

  DEFAULT_EXPIRY_TIME = 28.days * TIME_MULTIPLIER
  DEFAULT_PREMIUM_TIME = 7.days * TIME_MULTIPLIER
  JOB_TYPES = [ "Permanent", "Temporary", "Contract" ]

  # Relationships
  belongs_to :advertiser
  has_and_belongs_to_many :categories
  has_and_belongs_to_many :locations
  has_many :abuse_reports
  has_many :send_to_a_friends
  has_many :job_applications
  has_many :order_items, :as => :actionable

  attr_accessor :email_confirmation, :password_retype
  
  # Validations
  validates_presence_of :password, :on => :create, :message => "Please enter a password"
  validates_length_of :password, :on => :create, :minimum => 6, :message => "Please ensure your password is at least 6 characters long"
  validates_presence_of :job_title, :message => "Please specify a job title for this advert"
  validates_presence_of :job_type, :message => "Please choose a job type for this advert"
  validates_presence_of :description, :message => "Please ensure you give this advert a description"
  validates_presence_of :telephone, :message => "Please enter a telephone number"
  validates_presence_of :submitters_forename, :message => "Please enter your first name"
  validates_presence_of :submitters_surname, :message => "Please enter your surname"
  validates_presence_of :reference, :message => "Please supply a reference number of your choice to identify this advert"
  validates_format_of :email, :with => EMAIL_REGEX, :on => :create, :message => "Your e-mail looks to be invalid to us. Please use an e-mail with the following format: name@name.co.uk"
  validate :emails_are_the_same, :on => :create
  validate :passwords_are_the_same, :on => :create
  validate :check_nice_text_captcha
  validate :check_no_emails_in_description
  
  # Extensions
  extend TimeTravel
  scoped_search :on => :id, :default_operator => :like
  scoped_search :on => [ :reference, :job_title, :email ]
  scoped_search :in => :advertiser, :on => [:email, :forename, :surname] 
  scoped_search :in => :locations, :on => :name
  scoped_search :in => :categories, :on => :name
  accepts_nested_attributes_for :locations, :categories
  has_secure_password
  
  # Scopes
  # default_scope where(:approved => true)
  
  scope :approved, where(:approved => true)
  scope :archived, where(:archived => true)
  scope :unarchived, where(:archived => false)
  scope :active, lambda { approved.unarchived.where("active_until >= ?", Time.now) }
  scope :inactive, lambda { approved.where("active_until <= ?", Time.now) }
  scope :inactive_or_archived, lambda { approved.where("archived = ? or active_until <= ?", true, Time.now) }
  scope :premium, lambda { where("premium_until >= ?", Time.now) }
  scope :regular, lambda { where("premium_until is null OR premium_until <= ?", Time.now) }
  scope :most_recent_first, order("adverts.advert_date DESC")
  scope :most_premium_first, order("adverts.premium_until DESC")
  scope :in_last_seconds, lambda { |seconds| where("live_at BETWEEN ? AND ?", ((Time.now - seconds.to_i)-Time.now.sec), (Time.now-Time.now.sec-1)) }
  scope :in_location, lambda { |location| includes(:locations).where("locations.lft" => location.lft .. location.rgt) }
  scope :in_category, lambda { |category| includes(:categories).where("categories.lft" => category.lft .. category.rgt) }
  scope :by_active_status, lambda { |status| status == "1" ? active : inactive }
  scope :by_premium_status, lambda { |status| status == "1" ? premium : regular }
  scope :age_in_days, lambda { |age| where(:live_at => days_ago(age) .. days_ago(age-1)-1) }
  scope :expired_yesterday, lambda { where(:active_until => days_ago(1) .. days_ago(0)-1) }
  scope :premium_expired_yesterday, lambda { where(:premium_until => days_ago(1) .. days_ago(0)-1) }
  scope :for_subuser, lambda { |subuser| includes(:order_items => :order).where("adverts.subuser_id = ? OR orders.subuser_id = ?", subuser.id, subuser.id )}
  scope :not_associated_with_account, where(:advertiser_id => nil)

  # Callbacks
  before_create :set_advert_date, :set_expiry_date
  before_save :remove_premium_status_if_necessary

  def to_s
    job_title
  end
  
  def submitters_full_name
    [submitters_forename, submitters_surname].join " "
  end

  def submitters_company_name
    if advertiser and advertiser.company_name.present?
      advertiser.company_name
    elsif !advertiser and order_items.any? and order_items.first.order.company_name.present?
      order_items.first.order.company_name
    else
      ""
    end
  end
  
  def advertiser_contact_email
    if subuser
      subuser.email
    elsif advertiser
      advertiser.email
    else
      email
    end
  end

  def last_posted_date
    order_items.with_product(Product.advert.where(:action => "advertise").first).last.order.completed_at rescue created_at
  end
  
  def to_param
    "%d-%s" % [id, job_title.parameterize]
  end
  
  def never_advertised?
    !approved?
  end
  
  def premium?
    premium_until and premium_until >= Time.now
  end
  
  def active?
    active_until.present? and active_until >= Time.now
  end

  def active_and_not_archived?
    active? and !archived?
  end
  
  def token
    Digest::SHA1.hexdigest(SITE_NAME + password_digest)
  end
  
  def subuser
    if subuser_id.present?
      Subuser.find(subuser_id)
    elsif order_items.any? and order_items.first.order
      order_items.first.order.subuser
    else
      nil
    end
  end
   
  def make_premium
    premium?
  end

  def make_premium=(making_premium)
    if making_premium and making_premium == "0"
      @remove_premium_status = true
    end
  end

  def remove_premium_status_if_necessary
    if @remove_premium_status
      self.premium_until = nil
    end
  end

  def last_paid_order
    order_ids = order_items.map(&:order_id).uniq
    Order.completed.where(:id => order_ids).order("completed_at DESC").limit(1).last
  end

  def bitly_url
    if bitly_url_cache and bitly_url_cache.present?
      return bitly_url_cache
    else
      begin
        bitly = Bitly.new('thisisfocus','R_d05837dba0963c860ce50429a5a8f6ed')
        page_url = bitly.shorten(advert_url(self, :host => DEFAULT_URL_HOST))
        bitly_page_url = page_url.shorten
        if bitly_page_url.present?
          update_attributes! :bitly_url_cache => bitly_page_url
          return bitly_url_cache
        else
          return advert_url(self, :host => DEFAULT_URL_HOST)
        end
      rescue
        return advert_url(self, :host => DEFAULT_URL_HOST)
      end
    end
  end

  ### ACTION CHECKS ###
  
  def bumpable?
    active? and !premium?
  end
  
  def readvertisable?
    !active?
  end
  
  def premiumable?
    active? and !premium?
  end

  def archiveable?
    active? and !archived?
  end
  
  def unarchiveable?
    active? and archived?
  end
  
  ### ACTIONS ###
  
  def advertise!(order_item = nil)
    self.approved = true
    self.active_until = Time.now + DEFAULT_EXPIRY_TIME # Ensure a full run
    self.advert_date = Time.now # Base the advert on right now
    self.live_at = Time.now  # Record that the job first went live now
    self.archived = false # Ensure the job isn't archived
    save
  end

  def bump!(order_item = nil)
    self.advert_date = Time.now
    save
  end
    
  def premium_upgrade!(order_item = nil)
    self.premium_until = Time.now + DEFAULT_PREMIUM_TIME
    save
  end

  def archive!
    self.archived = true
    save
  end

  def unarchive!
    self.archived = false
    save
  end

private

  def emails_are_the_same
    if email != email_confirmation
      errors.add(:email_confirmation, 'Please ensure your e-mail address matches the confirmation field') unless self.send("email_confirmation").nil?
    end
  end

  def passwords_are_the_same
    if password != password_retype
      errors.add(:password_retype, 'Please ensure your password address matches the confirmation field') unless self.send("password_retype").nil?
    end
  end
  
  def set_advert_date
    self.advert_date = Time.now if advert_date.nil?
  end
  
  def set_expiry_date
    self.active_until = Time.now + DEFAULT_EXPIRY_TIME if active_until.nil?
  end
  
  def check_no_emails_in_description
    if description =~ /([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})/i
      errors.add(:description, "Email addresses are not allowed in job description field.")
    end
  end
  
end
