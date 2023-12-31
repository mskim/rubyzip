# frozen_string_literal: true

require 'test_helper'

class ZipExtraFieldTest < MiniTest::Test
  def test_new
    extra_pure = ::Zip::ExtraField.new('')
    extra_withstr = ::Zip::ExtraField.new('foo')
    extra_withstr_local = ::Zip::ExtraField.new('foo', local: true)

    assert_instance_of(::Zip::ExtraField, extra_pure)
    assert_instance_of(::Zip::ExtraField, extra_withstr)
    assert_instance_of(::Zip::ExtraField, extra_withstr_local)

    assert_equal('foo', extra_withstr['Unknown'].to_c_dir_bin)
    assert_equal('foo', extra_withstr_local['Unknown'].to_local_bin)
  end

  def test_unknownfield
    extra = ::Zip::ExtraField.new('foo')
    assert_equal('foo', extra['Unknown'].to_c_dir_bin)

    extra.merge('a')
    assert_equal('fooa', extra['Unknown'].to_c_dir_bin)

    extra.merge('barbaz')
    assert_equal('fooabarbaz', extra['Unknown'].to_c_dir_bin)

    extra.merge('bar', local: true)
    assert_equal('bar', extra['Unknown'].to_local_bin)
    assert_equal('fooabarbaz', extra['Unknown'].to_c_dir_bin)
  end

  def test_bad_header_id
    str = "ut\x5\0\x3\250$\r@"
    ut = nil
    assert_output('', /WARNING/) do
      ut = ::Zip::ExtraField::UniversalTime.new(str)
    end
    assert_instance_of(::Zip::ExtraField::UniversalTime, ut)
    assert_nil(ut.mtime)
  end

  def test_ntfs
    str = +"\x0A\x00 \x00\x00\x00\x00\x00\x01\x00\x18\x00\xC0\x81\x17\xE8B\xCE\xCF\x01\xC0\x81\x17\xE8B\xCE\xCF\x01\xC0\x81\x17\xE8B\xCE\xCF\x01"
    extra = ::Zip::ExtraField.new(str)
    assert(extra.member?('NTFS'))
    t = ::Zip::DOSTime.at(1_410_496_497.405178)
    assert_equal(t, extra['NTFS'].mtime)
    assert_equal(t, extra['NTFS'].atime)
    assert_equal(t, extra['NTFS'].ctime)

    assert_equal(str.force_encoding('BINARY'), extra.to_local_bin)
  end

  def test_merge
    str = "UT\x5\0\x3\250$\r@Ux\0\0"
    extra1 = ::Zip::ExtraField.new('')
    extra2 = ::Zip::ExtraField.new(str)
    assert(!extra1.member?('UniversalTime'))
    assert(extra2.member?('UniversalTime'))
    extra1.merge(str)
    assert_equal(extra1['UniversalTime'].mtime, extra2['UniversalTime'].mtime)
  end

  def test_length
    str = "UT\x5\0\x3\250$\r@Ux\0\0Te\0\0testit"
    extra = ::Zip::ExtraField.new(str)
    assert_equal(extra.local_size, extra.to_local_bin.size)
    assert_equal(extra.c_dir_size, extra.to_c_dir_bin.size)
    extra.merge('foo')
    assert_equal(extra.local_size, extra.to_local_bin.size)
    assert_equal(extra.c_dir_size, extra.to_c_dir_bin.size)
  end

  def test_to_s
    str = "UT\x5\0\x3\250$\r@Ux\0\0Te\0\0testit"
    extra = ::Zip::ExtraField.new(str)
    assert_instance_of(String, extra.to_s)

    extra_len = extra.to_s.length
    extra.merge('foo', local: true)
    assert_equal(extra_len + 3, extra.to_s.length)
  end

  def test_equality
    str = "UT\x5\0\x3\250$\r@"
    extra1 = ::Zip::ExtraField.new(str)
    extra2 = ::Zip::ExtraField.new(str)
    extra3 = ::Zip::ExtraField.new(str)
    assert_equal(extra1, extra2)

    extra2['UniversalTime'].mtime = ::Zip::DOSTime.now
    assert(extra1 != extra2)

    extra3.create('IUnix')
    assert(extra1 != extra3)

    extra1.create('IUnix')
    assert_equal(extra1, extra3)
  end

  def test_read_local_extra_field
    ::Zip::File.open('test/data/local_extra_field.zip') do |zf|
      ['file1.txt', 'file2.txt'].each do |file|
        entry = zf.get_entry(file)

        assert_instance_of(::Zip::ExtraField, entry.extra)
        assert_equal(1_000, entry.extra['IUnix'].uid)
        assert_equal(1_000, entry.extra['IUnix'].gid)
      end
    end
  end

  def test_load_unknown_extra_field
    ::Zip::File.open('test/data/osx-archive.zip') do |zf|
      zf.each do |entry|
        # Check that there is only one occurance of the 'ux' extra field.
        assert_equal(0, entry.extra['Unknown'].to_c_dir_bin.rindex('ux'))
        assert_equal(0, entry.extra['Unknown'].to_local_bin.rindex('ux'))
      end
    end
  end
end
