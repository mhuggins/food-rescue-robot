require 'rails_helper'

RSpec.describe LogPart do
  describe 'this file needs to be completed' do
    let(:super_admin) { create(:volunteer, admin: true) }

    xit 'validates super_admin' do
      expect(super_admin).to be_valid
    end
  end
end
