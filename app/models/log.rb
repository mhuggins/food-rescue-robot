class Log < ActiveRecord::Base
  belongs_to :schedule_chain
  has_many :log_volunteers
  has_many :volunteers, :through => :log_volunteers,
           :conditions=>{"log_volunteers.active"=>true}
  has_many :inactive_volunteers, :through => :log_volunteers,
           :conditions=>{"log_volunteers.active"=>false}
  has_many :log_recipients
  has_many :recipients, :through => :log_recipients
  belongs_to :donor, :class_name => "Location", :foreign_key => "donor_id"
  belongs_to :scale_type
  belongs_to :transport_type
  belongs_to :region
  has_many :log_parts
  has_many :food_types, :through => :log_parts
  has_and_belongs_to_many :absences

  accepts_nested_attributes_for :log_recipients
  accepts_nested_attributes_for :log_volunteers
  accepts_nested_attributes_for :schedule_chain

  WhyZero = {1 => "No Food", 2 => "Didn't Happen"}

  validates :notes, presence: { if: Proc.new{ |a| a.complete and a.summed_weight == 0 and a.summed_count == 0 and a.why_zero == 2 },
             message: "can't be blank if weights/counts are all zero: let us know what happened!" }
  validates :transport_type_id, presence: { if: :complete }
  validates :donor_id, presence: { if: :complete }
  validates :scale_type_id, presence: { if: :complete }
  validates :when, presence: true
  validates :hours_spent, presence: { if: :complete }
  validates :why_zero, presence: { if: Proc.new{ |a| a.complete and a.summed_weight == 0 and a.summed_count == 0 } }

  attr_accessible :region_id, :donor_id, :why_zero,
                  :food_type_id, :transport_type_id, :flag_for_admin, :notes, 
                  :num_reminders, :transport, :when, :scale_type_id, :hours_spent,
                  :log_volunteers_attributes, :weight_unit, :volunteers_attributes,
                  :schedule_chain_id, :recipients_attributes, :log_recipients_attributes, :log_volunteers_attributes,
                  :id, :created_at, :updated_at, :complete, :recipient_ids, :volunteer_ids, :num_volunteers

  # units conversion on scale type --- we always store in lbs in the database
  before_save { |record|
    return if record.region.nil?
    record.scale_type = record.region.scale_types.first if record.scale_type.nil? and record.region.scale_types.length == 1
    unless record.scale_type.nil?
      record.weight_unit = record.scale_type.weight_unit if record.weight_unit.nil?
      record.log_parts.each{ |lp|
        if record.weight_unit == "kg"
          lp.weight = (lp.weight * (1.0/2.2).to_f).round(2)
        elsif record.weight_unit == "st"
          lp.weight = (conv_weight * (1.0/14.0).to_f).round(2)
        end
        lp.save
      }
      record.weight_unit = "lb"
    end
  }

  def has_volunteers?
    self.volunteers.count > 0
  end

  def no_volunteers?
    self.volunteers.count == 0
  end

  def covering_volunteers
    self.log_volunteers.collect{ |lv| lv.covering ? lv.volunteer : nil }.compact
  end

  def covered?
    nv = self.num_volunteers
    nv = self.schedule_chain.num_volunteers if nv.nil? and not self.schedule_chain.nil?
    nv.nil? ? self.has_volunteers? : self.volunteers.length >= nv
  end

  def has_volunteer? volunteer
    return false if volunteer.nil?
    self.volunteers.collect { |v| v.id }.include? volunteer.id
  end

  def summed_weight
    self.log_parts.collect{ |lp| lp.weight }.compact.sum
  end

  def summed_count
    self.log_parts.collect{ |lp| lp.count }.compact.sum
  end

  def prior_volunteers
    self.log_volunteers.collect{ |sv| (not sv.active) ? sv.volunteer : nil }.compact
  end

  #### CLASS METHODS

  # Creates a log for a given schedule (s) and date (d)
  # it is assumed that this is only called for donor schedule
  # items and si is the index of this donor in the schedule chain
  def self.from_donor_schedule(s,si,d)
    sc = s.schedule_chain
    log = Log.new
    log.schedule_chain_id = sc.id
    log.donor_id = s.location.id # assume this is a donor
    log.when = d
    log.region_id = sc.region_id
    sc.volunteers.each{ |v|
      log.log_volunteers << LogVolunteer.new(volunteer:v,log:log,active:true)
    }
    log.num_volunteers = sc.num_volunteers
    # list each recipient that follows this donor in the chain
    sc.schedules.each_with_index{ |s2,s2i|
      next if s2.location.nil? or s2i <= si or s2.is_pickup_stop?
      log.log_recipients << LogRecipient.new(recipient:s2.location,log:log)
    }
    s.schedule_parts.each{ |sp|
      log.log_parts << LogPart.new(food_type_id:sp.food_type.id,required:sp.required)
    }
    log
  end

  def self.pickup_count region_id
    Log.where(:region_id=>region_id, :complete=>true).count
  end

  def self.picked_up_by(volunteer_id,complete=true,limit=nil)
    if limit.nil?
      Log.joins(:log_volunteers).where("log_volunteers.volunteer_id = ? AND logs.complete=? AND log_volunteers.active",volunteer_id,complete).order('"logs"."when" DESC')
    else
      Log.joins(:log_volunteers).where("log_volunteers.volunteer_id = ? AND logs.complete=? AND log_volunteers.active",volunteer_id,complete).order('"logs"."when" DESC').limit(limit.to_i)
    end
  end

  def self.at(loc)
    if loc.is_donor
      return Log.joins(:food_types).select("sum(weight) as weight_sum, string_agg(food_types.name,', ') as food_types_combined, logs.id, logs.transport_type_id, logs.when").where("donor_id = ?",loc.id).group("logs.id, logs.transport_type_id, logs.when").order("logs.when ASC")
    else
      return Log.joins(:food_types,:recipients).select("sum(weight) as weight_sum,
          string_agg(food_types.name,', ') as food_types_combined, logs.id, logs.transport_type_id, logs.when, logs.donor_id").
          where("recipient_id=?",loc.id).group("logs.id, logs.transport_type_id, logs.when, logs.donor_id").order("logs.when ASC")
    end
  end

  def self.picked_up_weight(region_id=nil,volunteer_id=nil)
    cq = "logs.complete"
    vq = volunteer_id.nil? ? nil : "log_volunteers.volunteer_id=#{volunteer_id}"
    rq = region_id.nil? ? nil : "logs.region_id=#{region_id}"
    aq = "log_volunteers.active"
    Log.joins(:log_volunteers,:log_parts).where([cq,vq,rq,aq].compact.join(" AND ")).sum(:weight).to_f
  end

  def self.upcoming_for(volunteer_id)
    Log.joins(:log_volunteers).where("active AND \"when\" >= ? AND volunteer_id = ?",Time.zone.today,volunteer_id).order("logs.when")
  end

  def self.past_for(volunteer_id)
    Log.joins(:log_volunteers).where("active AND \"when\" < ? AND volunteer_id = ?",Time.zone.today,volunteer_id).order("logs.when")
  end

  def self.needing_coverage(region_id_list=nil,days_away=nil,limit=nil)
    unless region_id_list.nil?
      if days_away.nil?
        Log.where("\"when\" >= ?",Time.zone.today).where(:region_id=>region_id_list).order("logs.when").limit(limit).reject{ |l| l.covered? }
      else
        Log.where("\"when\" >= ? AND \"when\" <= ?",Time.zone.today,Time.zone.today+days_away).where(:region_id=>region_id_list).order("logs.when").limit(limit).reject{ |l| l.covered? }
      end
    else
      if days_away.nil?
        Log.where("\"when\" >= ?",Time.zone.today).order("logs.when").limit(limit).reject{ |l| l.covered? }
      else
        Log.where("\"when\" >= ? AND \"when\" <= ?",Time.zone.today,Time.zone.today+days_away).order("logs.when").limit(limit).reject{ |l| l.covered? }
      end
    end
  end

  # Turns a flat array into an array of arrays
  def self.group_by_schedule(logs)
    ret = []
    h = {}
    logs.each{ |l|
        if l.schedule_chain.nil?
        ret << [l]
      else
        k = [l.when,l.schedule_chain_id].join(":")
        if h[k].nil?
          h[k] = ret.length
          ret << []
        end
        ret[h[k]] << l
      end
    }
    ret
  end

  def self.being_covered region_id_list=nil
    unless region_id_list.nil?
      return self.select("logs.*, count(log_volunteers.volunteer_id) as prior_count").joins(:log_volunteers).
        where("NOT log_volunteers.active").
        where(:region_id=>region_id_list).
        where("\"when\" >= ?",Time.zone.today).
        group("logs.id")
    else
      return self.select("logs.*, count(log_volunteers.volunteer_id) as prior_count").joins(:log_volunteers).
        where("NOT log_volunteers.active").
        where("\"when\" >= ?",Time.zone.today).group("logs.id")
    end
  end

end