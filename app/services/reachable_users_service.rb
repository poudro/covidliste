class ReachableUsersService
  def initialize(campaign)
    @campaign = campaign
    @vaccination_center = campaign.vaccination_center
    @ranking_method = campaign.ranking_method
    @covering = ::GridCoordsService.new(@vaccination_center.lat, @vaccination_center.lon).get_covering(@campaign.max_distance_in_meters)
  end

  def get_users(limit = nil)
    return get_users_with_v2(limit) if @ranking_method == "v2"
    get_users_with_random(limit)
  end

  def get_vaccination_center_grid_query
    cells = @covering[:cells]
    "(grid_i, grid_j) IN ((" + cells.map { |sub| sub.join(",") }.join("),(") + "))"
  end

  def get_users_with_v2(limit = nil)
    sql = <<~SQL.tr("\n", " ").squish
      with reachable_users as (
        SELECT
        u.id as user_id,
        (SQRT((((:lat) - u.lat)*110.574)^2 + (((:lon) - u.lon)*111.320*COS(u.lat::float*3.14159/180))^2)) as distance
        FROM users u
        WHERE u.confirmed_at IS NOT NULL
        AND u.anonymized_at is NULL
        AND u.birthdate between (:min_date) and (:max_date)
        AND (SQRT((((:lat) - u.lat)*110.574)^2 + (((:lon) - u.lon)*111.320*COS(u.lat::float*3.14159/180))^2)) < (:rayon_km)
      )
      ,users_stats as (
        select
        u.id as user_id,
        (distance / 5.0)::int * 5 as distance_bucket,
        u.created_at::date as created_at,
        COUNT(m.id) filter (where vaccine_type = (:vaccine_type)) as vaccine_matches_count,
        COUNT(m.id) as total_matches_count,
        MAX(m.created_at) filter (where vaccine_type = (:vaccine_type))  as last_vaccine_match,
        MAX(m.created_at)::date as last_match,
        SUM(case when m.refused_at is not null and vaccine_type = (:vaccine_type) then 1 else 0 end) as vaccine_refusals_count,
        SUM(case when m.refused_at is not null then 1 else 0 end) as total_refusals_count
        from reachable_users r
        inner join users u on (r.user_id = u.id)
        left outer join matches m on (m.user_id = r.user_id)
        left outer join campaigns c on (c.id = m.campaign_id and c.status != 2)
        group by 1,2,3
        having
         (
           SUM(case when m.confirmed_at is not null then 1 else 0 end) <= 0
           AND (MAX(m.created_at) <= (:last_match_allowed_at) or MAX(m.created_at) is null)
         )
      )

      select
        user_id,
        vaccine_matches_count,
        distance_bucket,
        total_matches_count,
        COALESCE(last_match, created_at) as last_match_or_signup,
        vaccine_refusals_count,
        total_refusals_count
        from users_stats
        order by
        vaccine_matches_count asc,
        distance_bucket asc,
        total_matches_count,
        COALESCE(last_match, created_at) asc,
        vaccine_refusals_count asc,
        total_refusals_count asc
      limit (:limit)
    SQL
    params = {
      min_date: @campaign.max_age.years.ago,
      max_date: @campaign.min_age.years.ago,
      lat: @vaccination_center.lat,
      lon: @vaccination_center.lon,
      rayon_km: @campaign.max_distance_in_meters / 1000,
      vaccine_type: @campaign.vaccine_type,
      limit: limit,
      last_match_allowed_at: Match::NO_MORE_THAN_ONE_MATCH_PER_PERIOD.ago
    }
    sql = sql.sub! "__GRID_QUERY__", get_vaccination_center_grid_query
    query = ActiveRecord::Base.send(:sanitize_sql_array, [sql, params])
    User.where(id: ActiveRecord::Base.connection.execute(query).to_a.pluck("user_id"))
  end

  def get_users_with_random(limit = nil)
    User
      .confirmed
      .active
      .between_age(@campaign.min_age, @campaign.max_age)
      .where(get_vaccination_center_grid_query)
      .where("id not in (
      select user_id from matches m inner join campaigns c on (c.id = m.campaign_id)
      where m.user_id is not null
      and ((m.created_at >= ? and c.status != 2) or (m.confirmed_at is not null))
      )", Match::NO_MORE_THAN_ONE_MATCH_PER_PERIOD.ago) # exclude user_id that have been matched in the last 24 hours, or confirmed
      .order("RANDOM()")
      .limit(limit)
  end

  def get_users_count
    sql = <<~SQL.tr("\n", " ").squish
      SELECT
        COUNT(DISTINCT u.id) as count
        FROM users u
        left outer join matches m on (m.user_id = u.id and m.confirmed_at is not null)
        WHERE u.confirmed_at IS NOT NULL
        AND u.anonymized_at is NULL
        AND u.birthdate between (:min_date) and (:max_date)
        AND (SQRT((((:lat) - u.lat)*110.574)^2 + (((:lon) - u.lon)*111.320*COS(u.lat::float*3.14159/180))^2)) < (:rayon_km)
        AND m.id IS NULL
    SQL
    params = {
      min_date: @campaign.max_age.years.ago,
      max_date: @campaign.min_age.years.ago,
      lat: @vaccination_center.lat,
      lon: @vaccination_center.lon,
      rayon_km: @campaign.max_distance_in_meters / 1000,
      vaccine_type: @campaign.vaccine_type
    }
    query = ActiveRecord::Base.send(:sanitize_sql_array, [sql, params])
    ActiveRecord::Base.connection.execute(query).to_a.first["count"].to_i
  end
end
