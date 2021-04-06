class PushNewVaccinationCenterToSlack
  def initialize(vaccination_center)
    @vaccination_center = vaccination_center
  end

  def call
    text = "Un nouveau centre vient d'être créé #{creator} :point_right: #{cta}"
    attachments = [
      {
        color: "",
        fields: [
          {
            title: "Nom",
            value: @vaccination_center.name,
            short: true
          },
          {
            title: "Type",
            value: @vaccination_center.kind,
            short: true
          },
          {
            title: "Description",
            value: @vaccination_center.description
          },
          {
            title: "Adresse",
            value: @vaccination_center.address
          }
        ]
      }
    ].to_json
    SlackNotifierJob.set(wait: 5.seconds).perform_later(channel, text, attachments)
  end

  private

  def channel
    Rails.env.production? ? "nouveau-centre" : "test"
  end

  def cta
    "<#{Rails.application.routes.url_helpers.admin_vaccination_center_url(@vaccination_center)}|Aller à la validation>"
  end

  def creator
    if @vaccination_center.partners.none?
      "par un admin"
    else
      "par #{@vaccination_center.partners.first.name}"
    end
  end
end
