require_relative "../../../spec_helper"
platform_is :windows do
  verbose, $VERBOSE = $VERBOSE, nil

  require 'win32ole'

  describe "WIN32OLE_METHOD#return_type_detail" do
    before :each do
      ole_type = WIN32OLE_TYPE.new("Microsoft Shell Controls And Automation", "Shell")
      @m_browse_for_folder = WIN32OLE_METHOD.new(ole_type, "BrowseForFolder")
    end

    it "raises ArgumentError if argument is given" do
      -> { @m_browse_for_folder.return_type_detail(1) }.should raise_error ArgumentError
    end

    it "returns expected value for Shell Control's 'BrowseForFolder' method" do
      @m_browse_for_folder.return_type_detail.should be_kind_of Array
      @m_browse_for_folder.return_type_detail.should == ['PTR', 'USERDEFINED', 'Folder']
    end

  end

ensure
  $VERBOSE = verbose
end
